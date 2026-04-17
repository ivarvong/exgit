defmodule Exgit.Transport.File do
  alias Exgit.{ObjectStore, RefStore, Pack}

  @enforce_keys [:path]
  defstruct [:path]

  @type t :: %__MODULE__{path: Path.t()}

  @spec new(Path.t()) :: t()
  def new(path), do: %__MODULE__{path: path}

  def capabilities(%__MODULE__{}), do: {:ok, %{version: 2, agent: "exgit/file"}}

  def ls_refs(%__MODULE__{} = t, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :transport, :ls_refs],
      %{transport: :file, path: t.path},
      fn ->
        {:ok, refs} = result = do_ls_refs(t, opts)
        {:span, result, %{ref_count: length(refs)}}
      end
    )
  end

  defp do_ls_refs(%__MODULE__{path: path}, opts) do
    ref_store = RefStore.Disk.new(path)
    prefixes = Keyword.get(opts, :prefix, ["refs/"]) |> List.wrap()

    refs =
      prefixes
      |> Enum.flat_map(&RefStore.Disk.list_refs(ref_store, &1))
      |> Enum.uniq_by(&elem(&1, 0))

    head =
      if Enum.any?(prefixes, &(&1 == "" or &1 == "HEAD")) do
        case RefStore.Disk.resolve_ref(ref_store, "HEAD") do
          {:ok, sha} -> [{"HEAD", sha}]
          _ -> []
        end
      else
        []
      end

    {:ok, head ++ Enum.map(refs, fn {ref, value} -> resolve_ref(ref_store, ref, value) end)}
  end

  def fetch(%__MODULE__{} = t, wants, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :transport, :fetch],
      %{transport: :file, path: t.path, wants_count: length(wants)},
      fn ->
        case do_fetch(t, wants, opts) do
          {:ok, pack, summary} = result ->
            {:span, result,
             %{result_bytes: byte_size(pack), object_count: Map.get(summary, :objects, 0)}}
        end
      end
    )
  end

  defp do_fetch(%__MODULE__{path: path}, wants, _opts) do
    object_store = ObjectStore.Disk.new(path)
    objects = collect_reachable(object_store, wants, MapSet.new())

    if objects == [] do
      {:ok, <<>>, %{objects: 0}}
    else
      pack = Pack.Writer.build(objects)
      {:ok, pack, %{objects: length(objects)}}
    end
  end

  def push(%__MODULE__{} = t, updates, pack_bytes, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :transport, :push],
      %{
        transport: :file,
        path: t.path,
        update_count: length(updates),
        pack_bytes: byte_size(pack_bytes)
      },
      fn -> do_push(t, updates, pack_bytes, opts) end
    )
  end

  defp do_push(%__MODULE__{path: path}, updates, pack_bytes, _opts) do
    object_store = ObjectStore.Disk.new(path)
    ref_store = RefStore.Disk.new(path)

    if byte_size(pack_bytes) > 0 do
      case Pack.Reader.parse(pack_bytes) do
        {:ok, parsed_objects} ->
          for {type, _sha, content} <- parsed_objects do
            {:ok, obj} = Exgit.Object.decode(type, content)
            ObjectStore.Disk.put_object(object_store, obj)
          end

        {:error, reason} ->
          {:error, {:unpack_failed, reason}}
      end
    end

    results =
      Enum.map(updates, fn {ref, old_sha, new_sha} ->
        cond do
          new_sha == nil ->
            case RefStore.Disk.delete_ref(ref_store, ref) do
              :ok -> {ref, :ok}
              {:error, reason} -> {ref, {:error, reason}}
            end

          old_sha == nil ->
            case RefStore.Disk.write_ref(ref_store, ref, new_sha) do
              :ok -> {ref, :ok}
              {:error, reason} -> {ref, {:error, reason}}
            end

          true ->
            case RefStore.Disk.write_ref(ref_store, ref, new_sha, expected: old_sha) do
              :ok -> {ref, :ok}
              {:error, reason} -> {ref, {:error, reason}}
            end
        end
      end)

    {:ok, %{ref_results: results}}
  end

  # --- Internal ---

  defp resolve_ref(ref_store, ref, {:symbolic, target}) do
    case RefStore.Disk.resolve_ref(ref_store, target) do
      {:ok, sha} -> {ref, sha}
      _ -> {ref, nil}
    end
  end

  defp resolve_ref(_ref_store, ref, sha) when is_binary(sha), do: {ref, sha}

  defp collect_reachable(store, shas, seen) do
    shas
    |> Enum.reject(&MapSet.member?(seen, &1))
    |> Enum.flat_map(fn sha ->
      case ObjectStore.Disk.get_object(store, sha) do
        {:ok, obj} ->
          new_seen = MapSet.put(seen, sha)
          children = object_children(obj)
          [obj | collect_reachable(store, children, new_seen)]

        _ ->
          []
      end
    end)
  end

  defp object_children(%Exgit.Object.Commit{} = c),
    do: [Exgit.Object.Commit.tree(c) | Exgit.Object.Commit.parents(c)]

  defp object_children(%Exgit.Object.Tree{entries: entries}) do
    Enum.map(entries, fn {_mode, _name, sha} -> sha end)
  end

  defp object_children(%Exgit.Object.Tag{object: sha}), do: [sha]
  defp object_children(%Exgit.Object.Blob{}), do: []
end

defimpl Exgit.Transport, for: Exgit.Transport.File do
  defdelegate capabilities(t), to: Exgit.Transport.File
  defdelegate ls_refs(t, opts), to: Exgit.Transport.File
  defdelegate fetch(t, wants, opts), to: Exgit.Transport.File
  defdelegate push(t, updates, pack, opts), to: Exgit.Transport.File
end
