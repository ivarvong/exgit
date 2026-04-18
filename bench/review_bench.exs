# Benchmark harness for the post-review codebase.
#
# Runs the README workflow (lazy_clone + prefetch + grep) N times
# against ivarvong/pyex, captures per-phase telemetry, and reports
# median / p95 / min / max.
#
#     mix run bench/review_bench.exs [RUNS]

runs = case System.argv() do
  [] -> 100
  [n] -> String.to_integer(n)
  _ -> 100
end

url = "https://github.com/ivarvong/pyex"

IO.puts("Benchmark: #{runs} runs against #{url}")
IO.puts("========================================\n")

# Attach a per-run collector.
defmodule Collector do
  def new, do: :ets.new(:bench_events, [:public, :bag])

  def attach(table) do
    :telemetry.attach_many(
      "bench-#{:erlang.unique_integer([:positive])}",
      [
        [:exgit, :transport, :ls_refs, :stop],
        [:exgit, :transport, :fetch, :stop],
        [:exgit, :pack, :parse, :stop],
        [:exgit, :object_store, :get, :stop],
        [:exgit, :fs, :walk, :stop],
        [:exgit, :fs, :grep, :stop]
      ],
      fn event, measurements, _metadata, table ->
        us = System.convert_time_unit(measurements.duration, :native, :microsecond)
        :ets.insert(table, {event, us})
      end,
      table
    )
  end

  def durations(table, event) do
    :ets.match_object(table, {event, :_})
    |> Enum.map(fn {_, us} -> us end)
  end

  def count(table, event) do
    :ets.match_object(table, {event, :_}) |> length()
  end
end

defmodule Stats do
  def summarize([]), do: %{median: 0, p95: 0, min: 0, max: 0, n: 0}

  def summarize(nums) do
    sorted = Enum.sort(nums)
    n = length(sorted)
    %{
      median: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, min(n - 1, trunc(n * 0.95))),
      min: hd(sorted),
      max: List.last(sorted),
      n: n
    }
  end

  def fmt(us) when is_integer(us) do
    cond do
      us >= 1_000_000 -> :io_lib.format("~.2f s", [us / 1_000_000])
      us >= 1_000 -> :io_lib.format("~.1f ms", [us / 1_000])
      true -> :io_lib.format("~B us", [us])
    end
    |> IO.iodata_to_binary()
    |> to_string()
    |> String.pad_leading(10)
  end
end

# --- Per-run timing ---

defmodule Run do
  def one(url, run_idx) do
    phase_times = %{}

    # 1. lazy clone (refs only; objects fetched on demand)
    {t_clone, {:ok, repo}} = :timer.tc(fn -> Exgit.clone(url, lazy: true) end)

    # 2. prefetch blobs
    {t_prefetch, {:ok, repo}} =
      :timer.tc(fn -> Exgit.FS.prefetch(repo, "HEAD", blobs: true) end)

    # 3. grep
    {t_grep, results} =
      :timer.tc(fn ->
        Exgit.FS.grep(repo, "HEAD", "anthropic", case_insensitive: true)
        |> Enum.to_list()
      end)

    match_count = length(results)

    phase_times
    |> Map.put(:lazy_clone, t_clone)
    |> Map.put(:prefetch, t_prefetch)
    |> Map.put(:grep, t_grep)
    |> Map.put(:total, t_clone + t_prefetch + t_grep)
    |> Map.put(:match_count, match_count)
    |> Map.put(:run, run_idx)
  end
end

# Warm-up run (not counted) — establishes TLS session resumption
# pools, JIT warm, DNS cache.
IO.puts("Warm-up run...")
Run.one(url, 0)

# Collect telemetry only for the measured runs.
events_table = Collector.new()
Collector.attach(events_table)

IO.puts("Running #{runs} measured iterations...\n")

results =
  for i <- 1..runs do
    r = Run.one(url, i)

    if rem(i, 10) == 0 do
      IO.puts("  #{i}/#{runs}: total=#{Stats.fmt(r.total)} matches=#{r.match_count}")
    end

    r
  end

# --- Report ---

IO.puts("\n========================================")
IO.puts("Phase breakdown (#{runs} runs)")
IO.puts("========================================\n")

  IO.puts("#{String.pad_trailing("Phase", 30)}#{String.pad_leading("median", 12)}#{String.pad_leading("p95", 12)}#{String.pad_leading("min", 12)}#{String.pad_leading("max", 12)}")
  IO.puts(String.duplicate("-", 78))

for {phase, label} <- [
      {:lazy_clone, "1. clone(url, lazy: true)"},
      {:prefetch, "2. prefetch(blobs: true)"},
      {:grep, "3. grep"},
      {:total, "   total"}
    ] do
  stats = results |> Enum.map(& &1[phase]) |> Stats.summarize()
  IO.puts("#{String.pad_trailing(label, 25)}#{String.pad_leading(Stats.fmt(stats.median), 12)}#{String.pad_leading(Stats.fmt(stats.p95), 12)}#{String.pad_leading(Stats.fmt(stats.min), 12)}#{String.pad_leading(Stats.fmt(stats.max), 12)}")
end

IO.puts("\n========================================")
IO.puts("Telemetry event durations (across all runs)")
IO.puts("========================================\n")

IO.puts("#{String.pad_trailing("Event", 35)}#{String.pad_leading("median", 12)}#{String.pad_leading("p95", 12)}#{String.pad_leading("count", 10)}")
IO.puts(String.duplicate("-", 69))

for event <- [
      [:exgit, :transport, :ls_refs, :stop],
      [:exgit, :transport, :fetch, :stop],
      [:exgit, :pack, :parse, :stop],
      [:exgit, :fs, :walk, :stop],
      [:exgit, :fs, :grep, :stop],
      [:exgit, :object_store, :get, :stop]
    ] do
  durs = Collector.durations(events_table, event)
  stats = Stats.summarize(durs)
  label = event |> Enum.drop(1) |> Enum.map(&to_string/1) |> Enum.join(".") |> String.replace(".stop", "")

  IO.puts("#{String.pad_trailing(label, 35)}#{String.pad_leading(Stats.fmt(stats.median), 12)}#{String.pad_leading(Stats.fmt(stats.p95), 12)}#{String.pad_leading(to_string(stats.n), 10)}")
end

# Consistency check: match counts should be identical across runs.
match_counts = results |> Enum.map(& &1.match_count) |> Enum.uniq()
IO.puts("\nMatch-count consistency: #{inspect(match_counts)} (should be a single value)")

# Emit machine-readable summary so we can paste into the CHANGELOG/PR.
IO.puts("\n========================================")
IO.puts("Summary (median)")
IO.puts("========================================\n")

totals = results |> Enum.map(& &1.total)
stats = Stats.summarize(totals)
IO.puts("  total (median):  #{Stats.fmt(stats.median)}")
IO.puts("  total (p95):     #{Stats.fmt(stats.p95)}")
IO.puts("  total (min):     #{Stats.fmt(stats.min)}")
IO.puts("  runs:            #{stats.n}")
