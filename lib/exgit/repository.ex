defmodule Exgit.Repository do
  @enforce_keys [:object_store, :ref_store]
  defstruct [:object_store, :ref_store, :config, :path]

  @type t :: %__MODULE__{
          object_store: term(),
          ref_store: term(),
          config: Exgit.Config.t() | nil,
          path: Path.t() | nil
        }

  @spec new(term(), term(), keyword()) :: t()
  def new(object_store, ref_store, opts \\ []) do
    %__MODULE__{
      object_store: object_store,
      ref_store: ref_store,
      config: Keyword.get(opts, :config),
      path: Keyword.get(opts, :path)
    }
  end

  @doc """
  Convert a Promisor-backed repo into a plain `ObjectStore.Memory`-backed
  one, fetching every reachable object from `reference` through the
  Promisor's transport first.

  After materialization, the repo can be freely passed to streaming
  operations (`FS.walk/2`, `FS.grep/4`) without any special setup.

  On a repo that isn't Promisor-backed, materialize returns the repo
  unchanged.
  """
  @spec materialize(t(), String.t() | binary()) :: {:ok, t()} | {:error, term()}
  def materialize(%__MODULE__{object_store: %Exgit.ObjectStore.Promisor{}} = repo, reference) do
    # Prefetch ensures the full tree (and blobs) are in the cache.
    with {:ok, repo} <- Exgit.FS.prefetch(repo, reference, blobs: true) do
      # Now unwrap: keep just the Memory cache as the new store.
      %Exgit.ObjectStore.Promisor{cache: cache} = repo.object_store
      {:ok, %{repo | object_store: cache}}
    end
  end

  def materialize(%__MODULE__{} = repo, _reference), do: {:ok, repo}
end
