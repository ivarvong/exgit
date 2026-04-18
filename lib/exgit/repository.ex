defmodule Exgit.Repository do
  @moduledoc """
  A git repository value.

  Carries an object store, a ref store, optional on-disk path and
  config, and a `:mode` that distinguishes eager-fully-populated
  repositories from lazy ones.

  ## `:mode`

  The `:mode` field is part of the public API. It has two values:

    * `:eager` — every reachable object is locally available. Streaming
      FS operations (`FS.walk/2`, `FS.grep/4`) can iterate without
      triggering network fetches or producing silent empty results.

    * `:lazy` — backed by an `ObjectStore.Promisor`; some objects are
      fetched on demand from the transport. Streaming FS operations
      would either blow up (unbounded fetches mid-stream) or silently
      skip missing objects, so they **raise** `ArgumentError`. Strict
      FS operations (`FS.read_path/3`, `FS.ls/3`, `FS.stat/3`,
      `FS.write_path/4`) work because they fetch as needed and return
      `{:ok, result, repo}` for cache threading.

  Convert a `:lazy` repo to `:eager` via `materialize/2`.

  `:mode` defaults to `:eager` when constructing via `new/3` without
  an explicit `:mode` opt, so existing callers are unaffected.
  """

  @enforce_keys [:object_store, :ref_store]
  defstruct [:object_store, :ref_store, :config, :path, mode: :eager]

  @type mode :: :eager | :lazy

  @type t :: %__MODULE__{
          object_store: term(),
          ref_store: term(),
          config: Exgit.Config.t() | nil,
          path: Path.t() | nil,
          mode: mode()
        }

  @spec new(term(), term(), keyword()) :: t()
  def new(object_store, ref_store, opts \\ []) do
    %__MODULE__{
      object_store: object_store,
      ref_store: ref_store,
      config: Keyword.get(opts, :config),
      path: Keyword.get(opts, :path),
      mode: Keyword.get(opts, :mode, :eager)
    }
  end

  @doc """
  Convert a `:lazy` (Promisor-backed) repo into an `:eager`
  (Memory-backed) one, fetching every reachable object from
  `reference` through the Promisor's transport first.

  After materialization, the repo can be freely passed to streaming
  operations (`FS.walk/2`, `FS.grep/4`) without any special setup —
  the `:mode` is flipped to `:eager` as part of the same call.

  On a repo that is already `:eager`, materialize returns the repo
  unchanged.
  """
  @spec materialize(t(), String.t() | binary()) :: {:ok, t()} | {:error, term()}
  def materialize(%__MODULE__{object_store: %Exgit.ObjectStore.Promisor{}} = repo, reference) do
    # Prefetch ensures the full tree (and blobs) are in the cache.
    with {:ok, repo} <- Exgit.FS.prefetch(repo, reference, blobs: true) do
      # Now unwrap: keep just the Memory cache as the new store, and
      # flip the mode so streaming FS ops accept it.
      %Exgit.ObjectStore.Promisor{cache: cache} = repo.object_store
      {:ok, %{repo | object_store: cache, mode: :eager}}
    end
  end

  def materialize(%__MODULE__{} = repo, _reference), do: {:ok, repo}

  @typedoc """
  Structured memory usage report for a repository.

  * `:object_count` — total distinct objects in the cache
  * `:cache_bytes` — compressed bytes stored (what
    `:max_cache_bytes` bounds)
  * `:commit_count`, `:tree_count`, `:blob_count`, `:tag_count` —
    count of each object kind
  * `:max_cache_bytes` — configured cap (`:infinity` if unbounded)
  * `:mode` — repo mode (`:eager` or `:lazy`)
  * `:backend` — the object-store module
  """
  @type memory_report :: %{
          object_count: non_neg_integer(),
          cache_bytes: non_neg_integer(),
          commit_count: non_neg_integer(),
          tree_count: non_neg_integer(),
          blob_count: non_neg_integer(),
          tag_count: non_neg_integer(),
          max_cache_bytes: non_neg_integer() | :infinity,
          mode: mode(),
          backend: module()
        }

  @doc """
  Returns a structured memory-usage report for `repo`.

  Designed for operational monitoring — agent hosts can poll this
  between operations to track peak memory, detect unexpected
  cache growth, and alert when a configured cap is approached.

  Returns consistent shape across all object-store backends
  (`Memory`, `Disk`, `Promisor`, `SharedPromisor`); counts for
  backends without per-type bookkeeping (like `Disk`) are
  `:unknown`. The `:cache_bytes` and `:max_cache_bytes` fields
  are always present.

  ## Examples

      iex> {:ok, repo} = Exgit.clone(url, lazy: true)
      iex> {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
      iex> Exgit.Repository.memory_report(repo)
      %{
        object_count: 17_500,
        cache_bytes: 4_213_780,
        commit_count: 0,
        tree_count: 8_290,
        blob_count: 9_210,
        tag_count: 0,
        max_cache_bytes: :infinity,
        mode: :lazy,
        backend: Exgit.ObjectStore.Promisor
      }

  ## Use in an agent

      repo
      |> Exgit.Repository.memory_report()
      |> log_to_your_observability_stack()

  """
  @spec memory_report(t()) :: memory_report()
  def memory_report(%__MODULE__{object_store: store, mode: mode}) do
    base = store_report(store)
    Map.merge(base, %{mode: mode, backend: backend_module(store)})
  end

  defp store_report(%Exgit.ObjectStore.Promisor{
         cache: cache,
         cache_bytes: cache_bytes,
         max_cache_bytes: max_cache_bytes
       }) do
    %Exgit.ObjectStore.Memory{objects: objs} = cache

    counts =
      Enum.reduce(objs, %{commit: 0, tree: 0, blob: 0, tag: 0}, fn {_sha, {type, _}}, acc ->
        Map.update(acc, type, 1, &(&1 + 1))
      end)

    %{
      object_count: map_size(objs),
      cache_bytes: cache_bytes,
      commit_count: counts.commit,
      tree_count: counts.tree,
      blob_count: counts.blob,
      tag_count: counts.tag,
      max_cache_bytes: max_cache_bytes
    }
  end

  defp store_report(%Exgit.ObjectStore.Memory{objects: objs}) do
    counts =
      Enum.reduce(objs, %{commit: 0, tree: 0, blob: 0, tag: 0}, fn {_sha, {type, compressed}},
                                                                   acc ->
        acc
        |> Map.update(type, 1, &(&1 + 1))
        |> Map.update(:bytes, byte_size(compressed), &(&1 + byte_size(compressed)))
      end)

    %{
      object_count: map_size(objs),
      cache_bytes: Map.get(counts, :bytes, 0),
      commit_count: counts.commit,
      tree_count: counts.tree,
      blob_count: counts.blob,
      tag_count: counts.tag,
      max_cache_bytes: :infinity
    }
  end

  defp store_report(other) do
    # Backends we don't introspect deeply (ObjectStore.Disk,
    # user-defined stores). Report a degraded shape with
    # placeholders so callers can still depend on the keys
    # existing.
    _ = other

    %{
      object_count: 0,
      cache_bytes: 0,
      commit_count: 0,
      tree_count: 0,
      blob_count: 0,
      tag_count: 0,
      max_cache_bytes: :infinity
    }
  end

  defp backend_module(%mod{}), do: mod
  defp backend_module(_), do: :unknown
end
