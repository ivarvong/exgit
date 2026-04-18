defmodule Exgit.Transport.File do
  @moduledoc """
  `Exgit.Transport` implementation that reads from and writes to a
  local on-disk git repository (bare or non-bare) without going
  over the network.

  Used by tests, by local roundtrip workflows, and as a reference
  implementation of the transport protocol. `fetch/3` walks the
  disk object store to collect reachable objects and assembles a
  pack; `push/4` unpacks the received pack into disk and applies
  ref updates with CAS semantics.
  """

  # See `Exgit.Walk` for the MapSet-opacity rationale. The
  # `collect_reachable/3` traversal uses a MapSet seen-set.
  @dialyzer :no_opaque

  alias Exgit.{ObjectStore, Pack, RefStore}

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
        {:ok, refs, meta} = result = do_ls_refs(t, opts)

        {:span, result, %{ref_count: length(refs), has_head: Map.has_key?(meta, :head)}}
      end
    )
  end

  # Returns `{:ok, refs, meta}` — the same 3-tuple shape as
  # `Transport.HTTP.ls_refs/2`. `meta.head` is the HEAD symref
  # target when HEAD resolves to another ref; `meta.peeled` is left
  # absent (the file transport doesn't currently peel annotated
  # tags). The shape is part of the `Exgit.Transport` protocol
  # contract.
  defp do_ls_refs(%__MODULE__{path: path}, opts) do
    ref_store = RefStore.Disk.new(path)
    prefixes = Keyword.get(opts, :prefix, ["refs/"]) |> List.wrap()

    # Whether to include a `{"HEAD", sha}` entry in the refs list.
    # Matches git protocol v2 behavior: HEAD appears in the list only
    # when the caller explicitly asks for it via an empty prefix or
    # `"HEAD"`.
    include_head_entry? = Enum.any?(prefixes, &(&1 == "" or &1 == "HEAD"))

    refs =
      prefixes
      |> Enum.reject(&(&1 == "HEAD"))
      |> Enum.flat_map(&RefStore.Disk.list_refs(ref_store, &1))
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {ref, value} -> resolve_ref(ref_store, ref, value) end)

    # HEAD's symref target is ALWAYS surfaced in `meta.head` when
    # available — cheap to compute, and callers that care about the
    # default branch shouldn't have to also ask for HEAD in the
    # prefix list. This mirrors how `Transport.HTTP.ls_refs/2`
    # unconditionally emits symref info.
    {head_entry, head_target} = read_head(ref_store)

    all_entries =
      if include_head_entry?, do: [head_entry | refs], else: refs

    all_entries =
      all_entries
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn {ref, _sha} -> keep_ref?(ref, path) end)

    meta =
      case head_target do
        nil -> %{}
        target -> %{head: target}
      end

    {:ok, all_entries, meta}
  end

  # Read HEAD from the disk ref store. Returns `{head_entry,
  # head_target}` where `head_entry` is the `{"HEAD", sha}` pair to
  # include in the refs list, and `head_target` is the symbolic
  # target (e.g. `"refs/heads/main"`) to lift into `meta.head`.
  defp read_head(ref_store) do
    with {:ok, {:symbolic, target}} <- RefStore.Disk.read_ref(ref_store, "HEAD"),
         {:ok, sha} <- RefStore.Disk.resolve_ref(ref_store, "HEAD") do
      {{"HEAD", sha}, target}
    else
      # Detached HEAD or packed-only HEAD — no symref target, but
      # we still want to surface the resolved sha.
      _ ->
        case RefStore.Disk.resolve_ref(ref_store, "HEAD") do
          {:ok, sha} -> {{"HEAD", sha}, nil}
          _ -> {nil, nil}
        end
    end
  end

  defp keep_ref?(ref, path) do
    if Exgit.RefName.valid?(ref) do
      true
    else
      :telemetry.execute(
        [:exgit, :security, :ref_rejected],
        %{count: 1},
        %{source: path, ref: ref}
      )

      false
    end
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

    # Unpack pack bytes into the object store as a side-effect. The
    # `_ =` binding makes the discarded result explicit for
    # Dialyzer's `:unmatched_returns` flag — previously the `if`'s
    # `nil | [any]` return was silently dropped.
    _ = maybe_unpack(object_store, pack_bytes)

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

  # Decode + import every object from `pack_bytes` into the disk
  # store. Returns `:ok` on success, `{:error, reason}` on a malformed
  # pack. `<<>>` pack is a valid no-op (pure-delete push).
  defp maybe_unpack(_store, <<>>), do: :ok

  defp maybe_unpack(store, pack_bytes) do
    case Pack.Reader.parse(pack_bytes) do
      {:ok, parsed_objects} ->
        Enum.each(parsed_objects, fn {type, _sha, content} ->
          {:ok, obj} = Exgit.Object.decode(type, content)
          ObjectStore.Disk.put_object(store, obj)
        end)

      {:error, reason} ->
        {:error, {:unpack_failed, reason}}
    end
  end

  defp resolve_ref(ref_store, ref, {:symbolic, target}) do
    case RefStore.Disk.resolve_ref(ref_store, target) do
      {:ok, sha} -> {ref, sha}
      _ -> {ref, nil}
    end
  end

  defp resolve_ref(_ref_store, ref, sha) when is_binary(sha), do: {ref, sha}

  @spec collect_reachable(ObjectStore.Disk.t(), [binary()], MapSet.t()) :: [Exgit.Object.t()]
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
