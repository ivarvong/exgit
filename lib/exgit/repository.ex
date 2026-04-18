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
end
