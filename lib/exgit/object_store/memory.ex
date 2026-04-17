defmodule Exgit.ObjectStore.Memory do
  @moduledoc false

  # Stores objects as {type_atom, zlib_compressed_content} for memory efficiency.
  # Objects are decoded on demand when `get` is called.

  defstruct objects: %{}

  @type t :: %__MODULE__{objects: %{binary() => {atom(), binary()}}}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec get_object(t(), binary()) :: {:ok, Exgit.Object.t()} | {:error, :not_found}
  def get_object(%__MODULE__{objects: objects}, sha) do
    case Map.fetch(objects, sha) do
      {:ok, {type, compressed}} ->
        content = :zlib.uncompress(compressed)
        Exgit.Object.decode(type, content)

      :error ->
        {:error, :not_found}
    end
  end

  @spec put_object(t(), Exgit.Object.t()) :: {:ok, binary(), t()}
  def put_object(%__MODULE__{objects: objects} = store, object) do
    sha = Exgit.Object.sha(object)
    type = Exgit.Object.type(object)
    content = Exgit.Object.encode(object) |> IO.iodata_to_binary()
    compressed = :zlib.compress(content)
    {:ok, sha, %{store | objects: Map.put(objects, sha, {type, compressed})}}
  end

  @spec has_object?(t(), binary()) :: boolean()
  def has_object?(%__MODULE__{objects: objects}, sha), do: Map.has_key?(objects, sha)

  @spec import_objects(t(), [{atom(), binary(), binary()}]) :: {:ok, t()}
  def import_objects(%__MODULE__{objects: objects} = store, raw_objects) do
    new_objects =
      Enum.reduce(raw_objects, objects, fn {type, sha, content}, acc ->
        compressed = :zlib.compress(content)
        Map.put(acc, sha, {type, compressed})
      end)

    {:ok, %{store | objects: new_objects}}
  end
end

defimpl Exgit.ObjectStore, for: Exgit.ObjectStore.Memory do
  alias Exgit.ObjectStore.Memory
  alias Exgit.Telemetry

  def get(store, sha) do
    Telemetry.span(
      [:exgit, :object_store, :get],
      %{store: :memory, sha: sha},
      fn ->
        case Memory.get_object(store, sha) do
          {:ok, _} = ok -> {:span, ok, %{hit?: true}}
          other -> {:span, other, %{hit?: false}}
        end
      end
    )
  end

  def put(store, object) do
    Telemetry.span(
      [:exgit, :object_store, :put],
      %{store: :memory},
      fn ->
        {:ok, sha, _new_store} = result = Memory.put_object(store, object)
        {:span, result, %{sha: sha}}
      end
    )
  end

  def has?(store, sha) do
    Telemetry.span(
      [:exgit, :object_store, :has?],
      %{store: :memory, sha: sha},
      fn ->
        present? = Memory.has_object?(store, sha)
        {:span, present?, %{present?: present?}}
      end
    )
  end

  def import_objects(store, raw_objects),
    do: Memory.import_objects(store, raw_objects)
end
