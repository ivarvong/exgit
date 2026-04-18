defmodule Exgit.Profiler do
  @moduledoc """
  Lightweight profiler that aggregates `:telemetry` span events
  into a structured trace.

  `profile/1` runs a function while capturing every exgit
  telemetry event emitted by or beneath the call. The return
  value is `{result, profile}` where `profile` is a structured
  breakdown: per-event totals, call counts, peak memory (when
  available), and the ordered list of events for detailed
  drill-down.

  Designed for three audiences:

    * **Agent developers** running `Exgit.Profiler.profile(fn ->
      my_agent_step() end)` to see where time goes in ONE call.
      No telemetry-handler plumbing required — attach, run,
      detach happens automatically.

    * **Operational monitoring** where you want per-request
      breakdowns matched to the operation that triggered them.
      Attach once via `attach/1`, read back via `read/1`, detach
      via `detach/1`.

    * **Test suites** asserting invariants like "this operation
      triggered at most N transport.fetch calls" or "cache bytes
      never exceeded 64 MiB during this workload."

  The profiler attaches to the standard `[:exgit, *]` event tree,
  so anything the library emits is captured. Zero cost when no
  profile is active.

  ## Examples

      # One-shot profile of an agent-style session.
      {results, profile} =
        Exgit.Profiler.profile(fn ->
          {:ok, repo} = Exgit.clone(url, lazy: true)
          {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
          Exgit.FS.grep(repo, "HEAD", "anthropic") |> Enum.to_list()
        end)

      profile.totals
      # => %{
      #   "transport.fetch"    => %{count: 2, us: 850_000},
      #   "pack.parse"         => %{count: 2, us:  95_000},
      #   "fs.grep"            => %{count: 1, us:  11_000},
      #   "object_store.get"   => %{count: 275, us: 25_000},
      #   ...
      # }

      profile.peak_cache_bytes
      # => 3_506_422

      profile.events
      # full event stream, ordered by start time, for drill-down

  ## Attaching manually

  `profile/1` is a convenience that handles attach/detach for one
  call. For server processes that want to accumulate a profile
  across many calls, use `attach/1` + `read/1` + `detach/1`:

      {:ok, handle} = Exgit.Profiler.attach()

      # ... do work ...

      profile = Exgit.Profiler.read(handle)
      Exgit.Profiler.detach(handle)

  Thread-safe: the profiler uses an ETS table and atomic counters,
  so concurrent calls from multiple processes accumulate into the
  same profile without locking.
  """

  @events_to_watch [
    [:exgit, :transport, :ls_refs],
    [:exgit, :transport, :fetch],
    [:exgit, :transport, :push],
    [:exgit, :pack, :parse],
    [:exgit, :object_store, :get],
    [:exgit, :object_store, :put],
    [:exgit, :object_store, :has?],
    [:exgit, :object_store, :fetch_and_cache],
    [:exgit, :fs, :read_path],
    [:exgit, :fs, :ls],
    [:exgit, :fs, :stat],
    [:exgit, :fs, :walk],
    [:exgit, :fs, :grep]
  ]

  @type event_record :: %{
          event: String.t(),
          duration_us: non_neg_integer(),
          metadata: map(),
          started_at: integer()
        }

  @type totals :: %{String.t() => %{count: non_neg_integer(), us: non_neg_integer()}}

  @type t :: %{
          events: [event_record()],
          totals: totals(),
          peak_cache_bytes: non_neg_integer() | :unknown,
          total_us: non_neg_integer()
        }

  @type handle :: %{id: String.t(), table: :ets.tid()}

  @doc """
  Run `fun` with profiling enabled. Returns `{result, profile}`
  where `result` is `fun`'s return value and `profile` is a
  `t:t/0` map.

  Attaches + detaches automatically; profiling is scoped to the
  lifetime of the call.
  """
  @spec profile((-> result)) :: {result, t()} when result: var
  def profile(fun) when is_function(fun, 0) do
    {:ok, handle} = attach()

    try do
      t0 = System.monotonic_time()
      result = fun.()
      total_us = System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)

      profile = read(handle) |> Map.put(:total_us, total_us)
      {result, profile}
    after
      detach(handle)
    end
  end

  @doc """
  Attach a profiler to the `[:exgit, *]` event tree and return
  a `handle` for later `read/1` / `detach/1` calls.

  Returns `{:ok, handle}` on success. The handle is a plain map
  carrying the internal ETS table; treat it as opaque.
  """
  @spec attach() :: {:ok, handle()}
  def attach do
    id = "exgit-profiler-#{System.unique_integer([:positive])}"
    table = :ets.new(:exgit_profiler, [:public, :bag, {:write_concurrency, true}])

    stop_events = for e <- @events_to_watch, do: e ++ [:stop]

    _ =
      :telemetry.attach_many(
        id,
        stop_events,
        &__MODULE__.handle_event/4,
        table
      )

    {:ok, %{id: id, table: table}}
  end

  @doc false
  # Public because :telemetry's "don't use a local function"
  # warning requires a module-qualified MFA. Not intended for
  # external use.
  def handle_event(event_name, measurements, metadata, table) do
    do_handle_event(event_name, measurements, metadata, table)
  end

  @doc "Read the profile accumulated so far on `handle`."
  @spec read(handle()) :: t()
  def read(%{table: table}) do
    events =
      :ets.tab2list(table)
      |> Enum.map(fn {_key, record} -> record end)
      |> Enum.sort_by(& &1.started_at)

    totals = aggregate_totals(events)
    peak = peak_cache_bytes(events)

    %{
      events: events,
      totals: totals,
      peak_cache_bytes: peak,
      total_us: 0
    }
  end

  @doc "Detach the profiler and free its ETS table."
  @spec detach(handle()) :: :ok
  def detach(%{id: id, table: table}) do
    _ = :telemetry.detach(id)
    _ = :ets.delete(table)
    :ok
  end

  # ---- internals ----

  defp do_handle_event(event_name, measurements, metadata, table) do
    duration_us =
      case Map.fetch(measurements, :duration) do
        {:ok, native} -> System.convert_time_unit(native, :native, :microsecond)
        :error -> 0
      end

    started_at =
      case Map.fetch(measurements, :monotonic_time) do
        {:ok, m} -> m - System.convert_time_unit(duration_us, :microsecond, :native)
        :error -> System.monotonic_time()
      end

    record = %{
      event: event_name_to_string(event_name),
      duration_us: duration_us,
      metadata: metadata,
      started_at: started_at
    }

    :ets.insert(table, {:event, record})
  end

  defp event_name_to_string(parts) do
    parts
    |> Enum.drop(1)
    |> Enum.reject(&(&1 == :stop))
    |> Enum.map_join(".", &to_string/1)
  end

  defp aggregate_totals(events) do
    Enum.reduce(events, %{}, fn %{event: name, duration_us: us}, acc ->
      Map.update(
        acc,
        name,
        %{count: 1, us: us},
        fn %{count: c, us: t} -> %{count: c + 1, us: t + us} end
      )
    end)
  end

  defp peak_cache_bytes(events) do
    events
    |> Enum.flat_map(fn %{metadata: md} ->
      case Map.get(md, :cache_bytes) do
        n when is_integer(n) -> [n]
        _ -> []
      end
    end)
    |> case do
      [] -> :unknown
      xs -> Enum.max(xs)
    end
  end
end
