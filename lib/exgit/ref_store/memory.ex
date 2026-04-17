defmodule Exgit.RefStore.Memory do
  defstruct refs: %{}

  @type ref_value :: binary() | {:symbolic, String.t()}
  @type t :: %__MODULE__{refs: %{String.t() => ref_value()}}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec read_ref(t(), String.t()) :: {:ok, ref_value()} | {:error, :not_found}
  def read_ref(%__MODULE__{refs: refs}, ref) do
    case Map.fetch(refs, ref) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  @spec resolve_ref(t(), String.t()) ::
          {:ok, binary()} | {:error, :not_found | :too_deep | :cycle}
  def resolve_ref(store, ref), do: do_resolve(store, ref, MapSet.new(), 10)

  defp do_resolve(%__MODULE__{} = store, ref, seen, depth) do
    cond do
      MapSet.member?(seen, ref) ->
        {:error, :cycle}

      depth <= 0 ->
        {:error, :too_deep}

      true ->
        case read_ref(store, ref) do
          {:ok, {:symbolic, target}} ->
            do_resolve(store, target, MapSet.put(seen, ref), depth - 1)

          {:ok, sha} ->
            {:ok, sha}

          error ->
            error
        end
    end
  end

  @spec write_ref(t(), String.t(), ref_value(), keyword()) :: {:ok, t()} | {:error, term()}
  def write_ref(%__MODULE__{refs: refs} = store, ref, value, opts \\ []) do
    case Keyword.get(opts, :expected) do
      nil ->
        {:ok, %{store | refs: Map.put(refs, ref, value)}}

      expected ->
        if Map.get(refs, ref) == expected do
          {:ok, %{store | refs: Map.put(refs, ref, value)}}
        else
          {:error, :compare_and_swap_failed}
        end
    end
  end

  @spec delete_ref(t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def delete_ref(%__MODULE__{refs: refs} = store, ref) do
    if Map.has_key?(refs, ref) do
      {:ok, %{store | refs: Map.delete(refs, ref)}}
    else
      {:error, :not_found}
    end
  end

  @spec list_refs(t(), String.t()) :: [{String.t(), ref_value()}]
  def list_refs(%__MODULE__{refs: refs}, prefix \\ "") do
    refs
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
  end
end

defimpl Exgit.RefStore, for: Exgit.RefStore.Memory do
  def read(store, ref), do: Exgit.RefStore.Memory.read_ref(store, ref)
  def resolve(store, ref), do: Exgit.RefStore.Memory.resolve_ref(store, ref)
  def write(store, ref, value, opts), do: Exgit.RefStore.Memory.write_ref(store, ref, value, opts)
  def delete(store, ref), do: Exgit.RefStore.Memory.delete_ref(store, ref)
  def list(store, prefix), do: Exgit.RefStore.Memory.list_refs(store, prefix)
end
