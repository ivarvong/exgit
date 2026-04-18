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

  ## Concurrency

  Because the struct is pure, two concurrent `resolve(p, sha_a)` and
  `resolve(p, sha_b)` calls from the same `p` each fetch
  independently, and only the return value the caller threads
  forward "wins" — the other fetch's cache growth is discarded.
  This is a CACHE RACE, not a correctness race: both results are
  valid, but the merged cache is strictly smaller than if the calls
  had been serialized. For an agent workflow that reads one file at
  a time this is fine; for concurrent bulk reads, wrap the Promisor
  in a process (e.g. an `Agent` holding the struct).

  ## Integration

  `Exgit.FS` threads the updated repo through its strict operations
  (`read_path`, `ls`, `stat`, `write_path`) so callers get the grown
  cache back:

      {:ok, {mode, blob}, repo} = Exgit.FS.read_path(repo, "HEAD", path)

  Streaming operations (`FS.walk`, `FS.grep`) use the pure
  `ObjectStore.get/2` and do NOT grow the cache. For a warm cache,
  call `Exgit.FS.prefetch/2` up front.

  ## Memory

  The cache is unbounded by default. For long-running agent loops
  accumulating thousands of blob reads against a large repository,
  pass `:max_cache_bytes` to enable LRU eviction — the Promisor will
  drop the least-recently-inserted commits when the cache crosses
  the bound. Blobs and trees are NOT evicted on their own (git
  object access patterns don't cleanly map to LRU at the blob
  level), but commit eviction cascades via the haves-negotiation
  state.
  """

  alias Exgit.{ObjectStore, Pack, Transport}

  @enforce_keys [:cache, :transport]
  defstruct cache: nil,
            transport: nil,
            default_fetch_opts: [],
            # Incrementally-maintained priority queue of commit SHAs
            # by recency. `:gb_trees` keyed on recency counter; the
            # largest counter is the most recent. Replaces an earlier
            # `%{sha => counter}` map that had to be sorted on every
            # cache miss — a full sort of K entries per miss is bad
            # at K=100k.
            commit_queue: nil,
            # Monotonic counter; increments on each commit insertion.
            # Serves as the key in `commit_queue`.
            commit_counter: 0,
            # How many of the most-recent commits we ship as `have`
            # lines on a subsequent fetch. 256 matches git's cap.
            haves_cap: 256,
            # Total bytes of cached object content. Incrementally
            # maintained; used to drive LRU eviction when
            # `max_cache_bytes` is set.
            cache_bytes: 0,
            # Optional cap on cached object bytes. `nil` = unbounded.
            max_cache_bytes: nil

  @type t :: %__MODULE__{
          cache: ObjectStore.Memory.t(),
          transport: term(),
          default_fetch_opts: keyword(),
          commit_queue: :gb_trees.tree() | nil,
          commit_counter: non_neg_integer(),
          haves_cap: pos_integer(),
          cache_bytes: non_neg_integer(),
          max_cache_bytes: non_neg_integer() | nil
        }

  @doc """
  Build a fresh Promisor wrapping `transport`.

  Options:

    * `:initial_objects` — list of pre-decoded objects to seed the cache.
    * `:default_fetch_opts` — keyword list merged into every
      `Transport.fetch/3` call the Promisor makes. Used by `lazy_clone`
      to propagate things like the partial-clone filter spec onto
      subsequent on-demand fetches.
    * `:max_cache_bytes` — cap on total cached object bytes. When
      the cap is exceeded, the oldest commits (and their associated
      cached trees/blobs reached only via those commits) are
      evicted in FIFO order. `nil` (default) means unbounded — the
      cache grows until the process dies. Recommended for
      long-running agent loops: `64 * 1024 * 1024` (64 MiB).
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
      default_fetch_opts: Keyword.get(opts, :default_fetch_opts, []),
      commit_queue: :gb_trees.empty(),
      max_cache_bytes: Keyword.get(opts, :max_cache_bytes)
    }
  end

  @doc """
  True if the cache is empty (no objects). Provides a
  stable abstraction for callers that used to reach into
  `%Promisor{cache: %Memory{objects: objs}}` — e.g.
  `FS.require_non_promisor!/2`.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{cache: %ObjectStore.Memory{objects: objs}}),
    do: map_size(objs) == 0

  @doc """
  Look up `sha`. On a cache hit, returns `{:ok, obj, promisor}` where
  the promisor is unchanged. On a miss, fetches from the transport,
  caches every object the pack returned, and returns
  `{:ok, obj, new_promisor}` — the returned struct carries the grown
  cache.

  ## Fetch-but-not-found edge case

  If the server returns a pack that doesn't contain the specific
  SHA the client asked for (rare, but some partial-clone servers do
  this intentionally when the requested object is itself deferred),
  `resolve/2` returns `{:error, :not_found}`. The **grown cache is
  discarded** — callers who want to keep the side-effect of the
  fetch should call `resolve_with_fetch/2` instead, which threads
  the promisor forward even on error.
  """
  @spec resolve(t(), binary()) :: {:ok, Exgit.Object.t(), t()} | {:error, term()}
  def resolve(%__MODULE__{cache: cache} = p, sha) do
    case ObjectStore.Memory.get_object(cache, sha) do
      {:ok, obj} ->
        {:ok, obj, p}

      {:error, :not_found} ->
        case fetch_and_cache(p, sha) do
          {:ok, new_cache, new_promisor} ->
            case ObjectStore.Memory.get_object(new_cache, sha) do
              {:ok, obj} -> {:ok, obj, new_promisor}
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Like `resolve/2`, but threads the grown promisor back even when
  the requested SHA isn't found in the returned pack. Returns
  `{:error, reason, promisor}` on the fetch-but-not-found path so
  the caller can keep the cache side-effect.

  Use this when the cost of refetching cached sibling objects
  exceeds the cost of an extra tuple-shape branch in the caller.
  """
  @spec resolve_with_fetch(t(), binary()) ::
          {:ok, Exgit.Object.t(), t()} | {:error, term()} | {:error, term(), t()}
  def resolve_with_fetch(%__MODULE__{cache: cache} = p, sha) do
    case ObjectStore.Memory.get_object(cache, sha) do
      {:ok, obj} ->
        {:ok, obj, p}

      {:error, :not_found} ->
        case fetch_and_cache(p, sha) do
          {:ok, new_cache, new_promisor} ->
            case ObjectStore.Memory.get_object(new_cache, sha) do
              {:ok, obj} -> {:ok, obj, new_promisor}
              {:error, _} -> {:error, :not_found, new_promisor}
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
    obj_bytes = object |> Exgit.Object.encode() |> IO.iodata_to_binary() |> byte_size()

    {:ok, sha,
     %{p | cache: cache, cache_bytes: p.cache_bytes + obj_bytes}
     |> track_commit(object, sha)
     |> maybe_evict()}
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
    new_bytes = Enum.sum(for {_t, _s, c} <- raw_objects, do: byte_size(c))

    {:ok,
     %{p | cache: cache, cache_bytes: p.cache_bytes + new_bytes}
     |> track_commits(new_commits)
     |> maybe_evict()}
  end

  # Incrementally record that a commit SHA is in the cache.
  # `commit_queue` is a gb_tree keyed on a monotonic recency counter
  # (higher = more recent), so `:gb_trees.largest/1` gives us the N
  # most-recent commits for haves negotiation in O(N log K) — not
  # O(K log K) per miss as the prior map-and-sort implementation did.
  defp track_commit(%__MODULE__{} = p, %Exgit.Object.Commit{}, sha) do
    track_commits(p, [sha])
  end

  defp track_commit(%__MODULE__{} = p, _not_a_commit, _sha), do: p

  defp track_commits(%__MODULE__{commit_queue: q, commit_counter: c} = p, commit_list) do
    queue = q || :gb_trees.empty()

    {updated_queue, new_counter} =
      Enum.reduce(commit_list, {queue, c}, fn sha, {q2, n} ->
        {:gb_trees.insert(n, sha, q2), n + 1}
      end)

    %{p | commit_queue: updated_queue, commit_counter: new_counter}
  end

  @doc """
  Fetch `wants` from the transport with explicit fetch options (e.g.
  a partial-clone filter), and merge the returned objects into the
  cache. Returns `{:ok, new_promisor}`.

  Used by `Exgit.clone/2` (with `filter:`) to perform the eager
  commits+trees fetch under a `blob:none` filter at clone time. End
  users should normally rely on `resolve/2`, which handles misses
  transparently.
  """
  @spec fetch_with_filter(t(), [binary()], keyword()) :: {:ok, t()} | {:error, term()}
  def fetch_with_filter(%__MODULE__{transport: transport, cache: cache} = p, wants, opts) do
    case Transport.fetch(transport, wants, opts) do
      {:ok, pack_bytes, _summary} when byte_size(pack_bytes) > 0 ->
        case Pack.Reader.parse(pack_bytes) do
          {:ok, parsed} ->
            {:ok, new_cache} = ObjectStore.Memory.import_objects(cache, parsed)
            new_commits = for {:commit, sha, _} <- parsed, do: sha
            new_bytes = Enum.sum(for {_t, _s, c} <- parsed, do: byte_size(c))

            {:ok,
             %{p | cache: new_cache, cache_bytes: p.cache_bytes + new_bytes}
             |> track_commits(new_commits)
             |> maybe_evict()}

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

  # Pull the most recent N commit SHAs from the gb_tree-ordered
  # `commit_queue`. O(N log K) where N = haves_cap (256) and K is
  # the total commit count. The prior implementation sorted all K
  # entries on every miss — O(K log K), bad at K=100k.
  defp collect_commit_haves(%__MODULE__{commit_queue: nil}), do: []

  defp collect_commit_haves(%__MODULE__{commit_queue: q, haves_cap: cap}) do
    take_largest(q, cap, [])
  end

  defp take_largest(_q, 0, acc), do: Enum.reverse(acc)

  defp take_largest(q, n, acc) do
    case :gb_trees.size(q) do
      0 ->
        Enum.reverse(acc)

      _ ->
        {_key, sha, q2} = :gb_trees.take_largest(q)
        take_largest(q2, n - 1, [sha | acc])
    end
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
        # often pulls the entire ancestry.
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

                new_commits = for {:commit, c_sha, _} <- parsed, do: c_sha
                new_bytes = Enum.sum(for {_t, _s, c} <- parsed, do: byte_size(c))

                new_promisor =
                  %{p | cache: new_cache, cache_bytes: p.cache_bytes + new_bytes}
                  |> track_commits(new_commits)
                  |> maybe_evict()

                {:span, {:ok, new_cache, new_promisor},
                 %{object_count: length(parsed), cache_bytes: new_promisor.cache_bytes}}

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

  # Evict the oldest commits (and drop their cache bytes) until
  # `cache_bytes <= max_cache_bytes`. FIFO-by-commit-insertion is
  # cheaper than true LRU and correct in the common agent-loop case
  # where reads are biased toward a specific branch tip.
  #
  # Only commit objects are tracked in `commit_queue`; blobs and
  # trees reached only via an evicted commit effectively become
  # orphan in the cache but are still returned if the caller
  # addresses them by SHA directly. True aggressive reclamation
  # (walk tree-reachability and evict unreachable blobs) would be a
  # v0.3 item.
  defp maybe_evict(%__MODULE__{max_cache_bytes: nil} = p), do: p

  defp maybe_evict(%__MODULE__{cache_bytes: bytes, max_cache_bytes: cap} = p)
       when bytes <= cap,
       do: p

  defp maybe_evict(%__MODULE__{commit_queue: q} = p) do
    case :gb_trees.size(q) do
      0 ->
        # Nothing to evict. Cache exceeds cap but only because of
        # raw blob/tree entries we can't reclaim without a full
        # reachability scan. Stop trying to evict.
        :telemetry.execute(
          [:exgit, :object_store, :cache_overfull],
          %{bytes: p.cache_bytes, cap: p.max_cache_bytes},
          %{}
        )

        p

      _ ->
        {_key, sha, q2} = :gb_trees.take_smallest(q)

        # Drop the commit object from the Memory cache. Track the
        # byte delta.
        %ObjectStore.Memory{objects: objs} = p.cache

        {dropped_bytes, new_objs} =
          case Map.pop(objs, sha) do
            {nil, o} -> {0, o}
            {{_type, compressed}, o} -> {byte_size(compressed), o}
          end

        new_cache = %ObjectStore.Memory{p.cache | objects: new_objs}

        %{
          p
          | cache: new_cache,
            commit_queue: q2,
            cache_bytes: max(p.cache_bytes - dropped_bytes, 0)
        }
        |> maybe_evict()
    end
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
