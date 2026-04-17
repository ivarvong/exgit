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
end
