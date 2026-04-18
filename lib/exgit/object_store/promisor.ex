defmodule Exgit.ObjectStore.Promisor do
  @moduledoc """
  An object store that fetches missing objects on demand from a
  transport, caching them locally.

  The Promisor is a **pure value** — no processes, no pids, no shared
  state. Growing the cache requires the caller to thread the updated
  struct forward via `resolve/2`.

      {:ok, obj, promisor2} = Promisor.resolve(promisor, sha)
      {:ok, obj2, promisor3} = Promisor.resolve(promisor2, other_sha)

  Two callers holding the same `%Promisor{}` see the same cache.
  Comparing promisors by value (`==`) reflects their logical state.
  Sharing via message passing, snapshotting, or serialization just
  works.

  ## Integration

  `Exgit.FS` threads the updated repo through its strict operations
  (`read_path`, `ls`, `stat`, `write_path`) so callers get the grown
  cache back:

      {:ok, {mode, blob}, repo} = Exgit.FS.read_path(repo, "HEAD", path)

  Streaming operations (`FS.walk`, `FS.grep`) use the pure
  `ObjectStore.get/2` and do NOT grow the cache. For a warm cache,
  call `Exgit.FS.prefetch/2` up front.
  """

  alias Exgit.{ObjectStore, Pack, Transport}

  @enforce_keys [:cache, :transport]
  defstruct cache: nil,
            transport: nil,
            default_fetch_opts: [],
            # Incrementally-maintained set of commit SHAs currently in
            # the cache. Avoids O(N) full-map scans on every fetch miss.
            commit_shas: %{},
            # How many of the most-recent commits we ship as `have`
            # lines on a subsequent fetch. 256 matches git's cap.
            haves_cap: 256

  @type t :: %__MODULE__{
          cache: ObjectStore.Memory.t(),
          transport: term(),
          default_fetch_opts: keyword(),
          commit_shas: %{optional(binary()) => non_neg_integer()},
          haves_cap: pos_integer()
        }

  @doc """
  Build a fresh Promisor wrapping `transport`.

  Options:

    * `:initial_objects` — list of pre-decoded objects to seed the cache.
    * `:default_fetch_opts` — keyword list merged into every
      `Transport.fetch/3` call the Promisor makes. Used by `lazy_clone`
      to propagate things like the partial-clone filter spec onto
      subsequent on-demand fetches.
  """
  @spec new(transport :: term(), keyword()) :: t()
  def new(transport, opts \\ []) do
    initial = Keyword.get(opts, :initial_objects, [])

    cache =
      Enum.reduce(initial, ObjectStore.Memory.new(), fn obj, store ->
        {:ok, _, store} = ObjectStore.Memory.put_object(store, obj)
        store
      end)

    %__MODULE__{
      cache: cache,
      transport: transport,
      default_fetch_opts: Keyword.get(opts, :default_fetch_opts, [])
    }
  end

  @doc """
  Look up `sha`. On a cache hit, returns `{:ok, obj, promisor}` where
  the promisor is unchanged. On a miss, fetches from the transport,
  caches every object the pack returned, and returns
  `{:ok, obj, new_promisor}` — the returned struct carries the grown
  cache.
  """
  @spec resolve(t(), binary()) :: {:ok, Exgit.Object.t(), t()} | {:error, term()}
  def resolve(%__MODULE__{cache: cache} = p, sha) do
    case ObjectStore.Memory.get_object(cache, sha) do
      {:ok, obj} ->
        {:ok, obj, p}

      {:error, :not_found} ->
        case fetch_and_cache(p, sha) do
          {:ok, new_cache} ->
            case ObjectStore.Memory.get_object(new_cache, sha) do
              {:ok, obj} -> {:ok, obj, %{p | cache: new_cache}}
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Return a new Promisor with `object` inserted into its cache."
  @spec put(t(), Exgit.Object.t()) :: {:ok, binary(), t()}
  def put(%__MODULE__{cache: cache} = p, object) do
    {:ok, sha, cache} = ObjectStore.Memory.put_object(cache, object)
    {:ok, sha, %{p | cache: cache} |> track_commit(object, sha)}
  end

  @doc "True if `sha` is in the local cache. Does NOT trigger a fetch."
  @spec has_object?(t(), binary()) :: boolean()
  def has_object?(%__MODULE__{cache: cache}, sha) do
    ObjectStore.Memory.has_object?(cache, sha)
  end

  @doc "Merge `raw_objects` into the cache."
  @spec import_objects(t(), [{atom(), binary(), binary()}]) :: {:ok, t()}
  def import_objects(%__MODULE__{cache: cache} = p, raw_objects) do
    {:ok, cache} = ObjectStore.Memory.import_objects(cache, raw_objects)
    new_commits = for {:commit, sha, _} <- raw_objects, do: sha
    {:ok, %{p | cache: cache} |> track_commits(new_commits)}
  end

  # Incrementally record that a commit SHA is in the cache. Values in
  # `commit_shas` are a recency counter (higher = more recent) so we
  # can ship the most-recent N as haves.
  defp track_commit(%__MODULE__{} = p, %Exgit.Object.Commit{}, sha) do
    track_commits(p, [sha])
  end

  defp track_commit(%__MODULE__{} = p, _not_a_commit, _sha), do: p

  defp track_commits(%__MODULE__{commit_shas: shas} = p, commit_list) do
    base = map_size(shas)

    updated =
      commit_list
      |> Enum.with_index(base)
      |> Enum.reduce(shas, fn {sha, idx}, acc -> Map.put(acc, sha, idx) end)

    %{p | commit_shas: updated}
  end

  @doc """
  Fetch `wants` from the transport with explicit fetch options (e.g.
  a partial-clone filter), and merge the returned objects into the
  cache. Returns `{:ok, new_promisor}`.

  Used by `Exgit.lazy_clone` to perform the eager commits+trees fetch
  under a `blob:none` filter. End users should normally rely on
  `resolve/2` which handles misses transparently.
  """
  @spec fetch_with_filter(t(), [binary()], keyword()) :: {:ok, t()} | {:error, term()}
  def fetch_with_filter(%__MODULE__{transport: transport, cache: cache} = p, wants, opts) do
    case Transport.fetch(transport, wants, opts) do
      {:ok, pack_bytes, _summary} when byte_size(pack_bytes) > 0 ->
        case Pack.Reader.parse(pack_bytes) do
          {:ok, parsed} ->
            {:ok, new_cache} = ObjectStore.Memory.import_objects(cache, parsed)
            {:ok, %{p | cache: new_cache}}

          {:error, _} = err ->
            err
        end

      {:ok, <<>>, _} ->
        # Empty pack is fine — server just had nothing new for us.
        {:ok, p}

      {:error, _} = err ->
        err
    end
  end

  # Pull the most recent N commit SHAs from the incrementally-maintained
  # `commit_shas` set. O(K log K) where K is the total commit count;
  # the cap keeps the result small regardless.
  #
  # Git itself sends up to 256 haves, biased toward recent commits. We
  # mirror that — the sort lets a large, long-running Promisor still
  # prefer the commits a server is likeliest to already have.
  defp collect_commit_haves(%__MODULE__{commit_shas: shas, haves_cap: cap}) do
    shas
    |> Enum.sort_by(fn {_sha, recency} -> -recency end)
    |> Enum.take(cap)
    |> Enum.map(fn {sha, _} -> sha end)
  end

  # --- Internal ---

  defp fetch_and_cache(
         %__MODULE__{transport: transport, cache: cache, default_fetch_opts: opts} = p,
         sha
       ) do
    Exgit.Telemetry.span(
      [:exgit, :object_store, :fetch_and_cache],
      %{sha: sha},
      fn ->
        # Tell the server what we already have so it sends only the
        # missing object(s). Without haves, a `want <blob_sha>` fetch
        # often pulls the entire ancestry. We use the incrementally-
        # maintained commit set capped at `haves_cap` (256 by default)
        # so this is O(K log K) per miss, not O(N) over the whole map.
        haves = collect_commit_haves(p)
        effective_opts = Keyword.put(opts, :haves, haves)

        :telemetry.execute(
          [:exgit, :object_store, :haves_sent],
          %{count: length(haves)},
          %{sha: sha}
        )

        case Transport.fetch(transport, [sha], effective_opts) do
          {:ok, pack_bytes, _summary} when byte_size(pack_bytes) > 0 ->
            case Pack.Reader.parse(pack_bytes) do
              {:ok, parsed} ->
                {:ok, new_cache} = ObjectStore.Memory.import_objects(cache, parsed)
                {:span, {:ok, new_cache}, %{object_count: length(parsed)}}

              {:error, _} = err ->
                {:span, err, %{object_count: 0}}
            end

          {:ok, <<>>, _} ->
            {:span, {:error, {:empty_pack_for, sha}}, %{object_count: 0}}

          {:error, _} = err ->
            {:span, err, %{object_count: 0}}
        end
      end
    )
  end
end

defimpl Exgit.ObjectStore, for: Exgit.ObjectStore.Promisor do
  alias Exgit.ObjectStore.Promisor
  alias Exgit.Telemetry

  # Pure read — does NOT fetch on miss. Use `Promisor.resolve/2` to
  # grow the cache.
  def get(%Promisor{cache: cache}, sha) do
    Telemetry.span(
      [:exgit, :object_store, :get],
      %{store: :promisor, sha: sha},
      fn ->
        case Exgit.ObjectStore.get(cache, sha) do
          {:ok, _} = ok -> {:span, ok, %{hit?: true}}
          other -> {:span, other, %{hit?: false}}
        end
      end
    )
  end

  def put(store, object) do
    Telemetry.span(
      [:exgit, :object_store, :put],
      %{store: :promisor},
      fn ->
        {:ok, sha, _} = result = Promisor.put(store, object)
        {:span, result, %{sha: sha}}
      end
    )
  end

  def has?(store, sha) do
    Telemetry.span(
      [:exgit, :object_store, :has?],
      %{store: :promisor, sha: sha},
      fn ->
        present? = Promisor.has_object?(store, sha)
        {:span, present?, %{present?: present?}}
      end
    )
  end

  def import_objects(store, raw_objects),
    do: Promisor.import_objects(store, raw_objects)
end
