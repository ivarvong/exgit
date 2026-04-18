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
  had been serialized.

  For workloads that do **concurrent bulk reads** against the same
  repo (e.g. a grep agent spawning N tasks), use
  `Exgit.ObjectStore.SharedPromisor` — a GenServer wrapper that
  serializes cache access across processes and eliminates the
  cache race entirely.

  ## Integration

  `Exgit.FS` threads the updated repo through its strict operations
  (`read_path`, `ls`, `stat`, `write_path`) so callers get the grown
  cache back:

      {:ok, {mode, blob}, repo} = Exgit.FS.read_path(repo, "HEAD", path)

  Streaming operations (`FS.walk`, `FS.grep`) use the pure
  `ObjectStore.get/2` and do NOT grow the cache. For a warm cache,
  call `Exgit.FS.prefetch/2` up front.

  ## Memory

  The cache is bounded by default at 64 MiB. When the cap is
  exceeded, the oldest commits (and their associated cached
  trees/blobs reached only via those commits) are evicted in FIFO
  order. Pass `max_cache_bytes: :infinity` to opt into unbounded
  growth — recommended only for tests and short-lived scripts,
  since a long-running agent against a large monorepo can
  accumulate GB of state.

  ## Server negotiation (`haves`)

  On-demand fetches (`resolve/2` → `fetch_and_cache/2`) deliberately
  send **no `haves`** to the server. This is counter-intuitive —
  every bulk git fetch DOES send haves to avoid redundant transfer —
  but on-demand fetches have different semantics:

    * Bulk fetch (`Exgit.fetch/3`): "I'm at commit X, catch me up to
      ref Y." Haves save bandwidth by excluding objects reachable
      from X.

    * On-demand fetch (Promisor): "Ship me exactly this blob,
      please." Haves actively break this. A smart server (GitHub,
      anything running modern `git-upload-pack`) treats haves as a
      reachability closure — "the client has commit X, therefore
      they have everything reachable from X" — and returns an
      empty pack. The blob is "reachable" from any cached commit
      that points at its containing tree, so every partial-clone
      read after the first would fail.

  See `test/exgit/security/haves_empty_pack_test.exs` for an
  offline regression against this.

  ## Overfull behavior

  When the evictor runs out of commits to drop but `cache_bytes`
  is still above the cap, the cache is technically over-full.
  The `:on_overfull` option selects the policy:

    * `:log` (default) — emit `[:exgit, :object_store, :cache_overfull]`
      telemetry and keep going. Matches the previous behavior.
    * `:error` — next `put`/`resolve` returns
      `{:error, :cache_overfull, promisor}`. Force a fail-fast loop
      to surface misconfigured caps quickly.
    * `{:callback, fun}` — `fun.(promisor)` is invoked; its return
      value is discarded. Use for custom metrics, alerting, or
      graceful shutdown.
  """

  alias Exgit.{ObjectStore, Pack, Transport}

  @default_max_cache_bytes 64 * 1024 * 1024

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
            # Cap on cached object bytes. Integer byte count or
            # `:infinity` for unbounded.
            max_cache_bytes: @default_max_cache_bytes,
            # Policy when cache is over cap and no commits are
            # available for eviction. `:log | :error | {:callback, f}`.
            on_overfull: :log

  @type overfull_policy :: :log | :error | {:callback, (t() -> any())}

  @type t :: %__MODULE__{
          cache: ObjectStore.Memory.t(),
          transport: term(),
          default_fetch_opts: keyword(),
          commit_queue: :gb_trees.tree() | nil,
          commit_counter: non_neg_integer(),
          haves_cap: pos_integer(),
          cache_bytes: non_neg_integer(),
          max_cache_bytes: non_neg_integer() | :infinity,
          on_overfull: overfull_policy()
        }

  @doc """
  Build a fresh Promisor wrapping `transport`.

  Options:

    * `:initial_objects` — list of pre-decoded objects to seed the cache.
    * `:default_fetch_opts` — keyword list merged into every
      `Transport.fetch/3` call the Promisor makes. Used by `lazy_clone`
      to propagate things like the partial-clone filter spec onto
      subsequent on-demand fetches.
    * `:max_cache_bytes` — cap on total cached object bytes. Default
      is `64 * 1024 * 1024` (64 MiB). Pass `:infinity` to disable
      the cap; this is safe for tests and short scripts but risks
      OOM on long-running agent loops against large repos.
    * `:on_overfull` — policy when the eviction loop can't reduce
      `cache_bytes` below `max_cache_bytes` (commit queue empty;
      only raw blobs/trees left in the cache). One of:
        - `:log` (default) — emit
          `[:exgit, :object_store, :cache_overfull]` telemetry
          and keep accepting new objects.
        - `:error` — fail subsequent `put`/`resolve` with
          `{:error, :cache_overfull, promisor}`.
        - `{:callback, fun}` — invoke `fun.(promisor)`. Return
          value is ignored; raise for hard-fail.
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
      max_cache_bytes: Keyword.get(opts, :max_cache_bytes, @default_max_cache_bytes),
      on_overfull: Keyword.get(opts, :on_overfull, :log)
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

  ## Error shape

  Errors come in two flavors:

    * `{:error, reason}` — transport-level failure, no cache change.
      Returned when the fetch itself failed (connection error, HTTP
      non-2xx, malformed pack).
    * `{:error, reason, promisor}` — the fetch succeeded and the
      cache grew, but the specific SHA requested wasn't in the
      returned pack (rare; happens when a partial-clone server
      defers the requested object itself). Callers should thread
      the returned promisor forward to avoid refetching the sibling
      objects that WERE returned.

  Pattern-match on both shapes:

      case Promisor.resolve(p, sha) do
        {:ok, obj, p2} -> ...
        {:error, _, p2} -> ...      # grown cache, but sha missing
        {:error, _} -> ...          # fetch failed entirely
      end
  """
  @spec resolve(t(), binary()) ::
          {:ok, Exgit.Object.t(), t()} | {:error, term()} | {:error, term(), t()}
  def resolve(%__MODULE__{cache: cache} = p, sha) do
    case ObjectStore.Memory.get_object(cache, sha) do
      {:ok, obj} ->
        {:ok, obj, p}

      {:error, :not_found} ->
        resolve_miss(p, sha)
    end
  end

  defp resolve_miss(p, sha) do
    case fetch_and_cache(p, sha) do
      {:ok, new_cache, new_promisor} ->
        enforce_overfull(new_promisor, fn ->
          case ObjectStore.Memory.get_object(new_cache, sha) do
            {:ok, obj} ->
              {:ok, obj, new_promisor}

            {:error, _} ->
              # Fetch-but-not-found: thread the promisor so the
              # caller keeps the cache side-effect for the sibling
              # objects that DID come back in the pack.
              {:error, :not_found, new_promisor}
          end
        end)

      {:error, _} = err ->
        # Transport-level failure — nothing was cached. Return the
        # 2-tuple error shape.
        err
    end
  end

  @doc """
  Return a new Promisor with `object` inserted into its cache.

  When `:on_overfull` is `:error` and the post-insert cache exceeds
  `:max_cache_bytes` with no commits left to evict, returns
  `{:error, :cache_overfull, promisor}` instead — the promisor is
  still threaded back so the caller can inspect `cache_bytes` /
  decide what to do.
  """
  @spec put(t(), Exgit.Object.t()) ::
          {:ok, binary(), t()} | {:error, :cache_overfull, t()}
  def put(%__MODULE__{cache: cache} = p, object) do
    {:ok, sha, cache} = ObjectStore.Memory.put_object(cache, object)
    obj_bytes = object |> Exgit.Object.encode() |> IO.iodata_to_binary() |> byte_size()

    new_p =
      %{p | cache: cache, cache_bytes: p.cache_bytes + obj_bytes}
      |> track_commit(object, sha)
      |> maybe_evict()

    enforce_overfull(new_p, fn -> {:ok, sha, new_p} end)
  end

  # When the promisor is configured with `:on_overfull => :error`
  # and the cache is still over cap after eviction, return
  # `{:error, :cache_overfull, promisor}`. All other policies
  # forward the success thunk's result.
  defp enforce_overfull(%__MODULE__{on_overfull: :error} = p, success_fun) do
    if over_cap?(p), do: {:error, :cache_overfull, p}, else: success_fun.()
  end

  defp enforce_overfull(_p, success_fun), do: success_fun.()

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

  # --- Internal ---

  defp fetch_and_cache(
         %__MODULE__{transport: transport, cache: cache, default_fetch_opts: opts} = p,
         sha
       ) do
    Exgit.Telemetry.span(
      [:exgit, :object_store, :fetch_and_cache],
      %{sha: sha},
      fn ->
        # NO haves on on-demand fetches. This is a `want <sha>` for
        # a specific object the caller has determined is missing
        # from the local cache. Sending haves here is actively
        # harmful in the partial-clone case:
        #
        # After `clone(url, filter: {:blob, :none})` the local cache
        # contains the commit that references the blob. If we then
        # try to fetch that blob on-demand, a smart server (GitHub,
        # anything running `git upload-pack` with reachability
        # awareness) reasons: "the client has commit X, therefore
        # they have everything reachable from X, therefore they
        # already have this blob — nothing to send." Result: an
        # empty 32-byte pack, and the read_path call fails with
        # {:error, :not_found}.
        #
        # Haves are a bulk-fetch optimization (saving redundant
        # transfer when we're catching up to a new tip). For
        # single-object on-demand fetches the request IS the
        # optimization — the caller already knows what's missing.
        # Leaving haves empty costs us at most O(1) extra server
        # work and correctness is unambiguous.
        effective_opts = Keyword.put(opts, :haves, [])

        :telemetry.execute(
          [:exgit, :object_store, :haves_sent],
          %{count: 0},
          %{sha: sha, context: :on_demand_fetch}
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
  defp maybe_evict(%__MODULE__{max_cache_bytes: :infinity} = p), do: p

  defp maybe_evict(%__MODULE__{cache_bytes: bytes, max_cache_bytes: cap} = p)
       when bytes <= cap,
       do: p

  defp maybe_evict(%__MODULE__{commit_queue: q} = p) do
    case :gb_trees.size(q) do
      0 ->
        # Nothing to evict. Cache exceeds cap but only because of
        # raw blob/tree entries we can't reclaim without a full
        # reachability scan. Apply the configured overfull policy.
        apply_overfull_policy(p)

      _ ->
        {_key, sha, q2} = :gb_trees.take_smallest(q)

        # Drop the commit object from the Memory cache. Track the
        # byte delta. We pattern-match `p.cache` into a
        # `%ObjectStore.Memory{}` binding first so the subsequent
        # struct-update is visible to Elixir 1.19's type checker
        # (a struct update on a field-access expression is rejected
        # under --warnings-as-errors because the type is dynamic()
        # at that site).
        %ObjectStore.Memory{objects: objs} = cache = p.cache

        {dropped_bytes, new_objs} =
          case Map.pop(objs, sha) do
            {nil, o} -> {0, o}
            {{_type, compressed}, o} -> {byte_size(compressed), o}
          end

        new_cache = %ObjectStore.Memory{cache | objects: new_objs}

        %{
          p
          | cache: new_cache,
            commit_queue: q2,
            cache_bytes: max(p.cache_bytes - dropped_bytes, 0)
        }
        |> maybe_evict()
    end
  end

  # Called when the eviction loop is exhausted but `cache_bytes`
  # remains above `max_cache_bytes`. Runs the configured
  # `:on_overfull` policy and returns the (unchanged) promisor so
  # the pipeline keeps flowing.
  #
  # The `:error` policy doesn't actually raise or return an error
  # from this function — maybe_evict/1 is called during put, and
  # the error is surfaced by the public `put/2` / `resolve/2`
  # wrappers which test `over_cap?/1` after the fact.
  defp apply_overfull_policy(%__MODULE__{} = p) do
    :telemetry.execute(
      [:exgit, :object_store, :cache_overfull],
      %{bytes: p.cache_bytes, cap: p.max_cache_bytes},
      %{policy: overfull_policy_name(p.on_overfull)}
    )

    case p.on_overfull do
      :log ->
        :ok

      :error ->
        # Error policy is surfaced at the public API layer via
        # over_cap?/1, not from this helper. Telemetry fires so
        # operators see it.
        :ok

      {:callback, fun} when is_function(fun, 1) ->
        _ = fun.(p)
        :ok
    end

    p
  end

  @doc false
  @spec over_cap?(t()) :: boolean()
  def over_cap?(%__MODULE__{max_cache_bytes: :infinity}), do: false

  def over_cap?(%__MODULE__{cache_bytes: bytes, max_cache_bytes: cap}),
    do: bytes > cap

  defp overfull_policy_name(:log), do: :log
  defp overfull_policy_name(:error), do: :error
  defp overfull_policy_name({:callback, _}), do: :callback
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

  # The protocol's `put/2` spec is `{:ok, sha, store}` only, so we
  # can't surface `{:error, :cache_overfull, _}` through this path.
  # Callers that opt in to `:on_overfull => :error` must use
  # `Promisor.put/2` directly; the protocol call always uses the
  # equivalent of `:on_overfull => :log` to preserve the spec.
  def put(store, object) do
    Telemetry.span(
      [:exgit, :object_store, :put],
      %{store: :promisor},
      fn ->
        relaxed = %{store | on_overfull: :log}
        {:ok, sha, _} = result = Promisor.put(relaxed, object)
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
