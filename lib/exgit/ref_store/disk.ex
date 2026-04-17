defmodule Exgit.RefStore.Disk do
  @enforce_keys [:root]
  defstruct [:root]

  @type ref_value :: binary() | {:symbolic, String.t()}
  @type t :: %__MODULE__{root: Path.t()}

  @spec new(Path.t()) :: t()
  def new(root), do: %__MODULE__{root: root}

  @spec read_ref(t(), String.t()) :: {:ok, ref_value()} | {:error, :not_found | term()}
  def read_ref(%__MODULE__{root: root}, ref) do
    path = Path.join(root, ref)

    case File.read(path) do
      {:ok, content} ->
        case parse_ref_content(String.trim_trailing(content, "\n")) do
          {:ok, value} -> {:ok, value}
          {:error, _} = err -> err
        end

      {:error, :enoent} ->
        read_packed(root, ref)

      {:error, reason} ->
        {:error, reason}
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

  @spec write_ref(t(), String.t(), ref_value(), keyword()) :: :ok | {:error, term()}
  def write_ref(%__MODULE__{root: root}, ref, value, opts \\ []) do
    path = Path.join(root, ref)
    expected = Keyword.get(opts, :expected)

    case acquire_lock(path) do
      {:ok, lock_path} ->
        try do
          with :ok <- check_expected(path, expected),
               :ok <- write_locked(lock_path, value),
               :ok <- File.rename(lock_path, path) do
            :ok
          else
            err ->
              _ = File.rm(lock_path)
              err
          end
        rescue
          e ->
            _ = File.rm(lock_path)
            reraise e, __STACKTRACE__
        end

      {:error, :eexist} ->
        {:error, :ref_locked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Create <path>.lock with O_CREAT | O_EXCL. This is the serializing point:
  # only one writer can hold the lock at a time. Git itself uses exactly
  # this convention, so it is interoperable with the on-disk format.
  defp acquire_lock(path) do
    lock_path = path <> ".lock"

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case :file.open(lock_path, [:write, :exclusive, :raw, :binary]) do
        {:ok, io} ->
          :ok = :file.close(io)
          {:ok, lock_path}

        {:error, :eexist} ->
          {:error, :eexist}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Write + fsync into the lock file. We hold the file open long enough to
  # sync it so the rename cannot expose torn contents.
  defp write_locked(lock_path, value) do
    content = format_ref_value(value)

    case :file.open(lock_path, [:write, :raw, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- :file.write(io, content),
               :ok <- :file.sync(io) do
            :ok
          end
        after
          _ = :file.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_expected(_path, nil), do: :ok

  defp check_expected(path, expected) do
    case File.read(path) do
      {:ok, content} ->
        case parse_ref_content(String.trim_trailing(content, "\n")) do
          {:ok, ^expected} -> :ok
          {:ok, _} -> {:error, :compare_and_swap_failed}
          {:error, _} = err -> err
        end

      {:error, :enoent} ->
        # The file must exist when caller passed a non-nil expected. Nil
        # expected means "create from scratch"; that branch took the
        # `:ok` path above.
        {:error, :compare_and_swap_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_ref(t(), String.t()) :: :ok | {:error, :not_found}
  def delete_ref(%__MODULE__{root: root}, ref) do
    path = Path.join(root, ref)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
    end
  end

  @spec list_refs(t(), String.t()) :: [{String.t(), ref_value()}]
  def list_refs(%__MODULE__{root: root}, prefix \\ "refs/") do
    loose = list_loose_refs(root, prefix)
    packed = list_packed_refs(root, prefix)

    loose_keys = MapSet.new(Enum.map(loose, &elem(&1, 0)))

    packed
    |> Enum.reject(fn {ref, _} -> MapSet.member?(loose_keys, ref) end)
    |> Enum.concat(loose)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # --- Internal: reading ---

  defp parse_ref_content("ref: " <> target), do: {:ok, {:symbolic, target}}

  defp parse_ref_content(hex) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, {:corrupt_ref, :invalid_hex}}
    end
  end

  defp parse_ref_content(_), do: {:error, {:corrupt_ref, :unexpected_content}}

  defp read_packed(root, ref) do
    packed_path = Path.join(root, "packed-refs")

    case File.read(packed_path) do
      {:ok, content} ->
        case find_in_packed(content, ref) do
          {:ok, _} = result -> result
          nil -> {:error, :not_found}
        end

      {:error, :enoent} ->
        {:error, :not_found}
    end
  end

  defp find_in_packed(content, ref) do
    content
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case parse_packed_line(line) do
        {^ref, sha} -> {:ok, sha}
        _ -> nil
      end
    end)
  end

  defp parse_packed_line("#" <> _), do: nil
  defp parse_packed_line("^" <> _), do: nil
  defp parse_packed_line(""), do: nil

  defp parse_packed_line(line) do
    case String.split(line, " ", parts: 2) do
      [hex, ref] when byte_size(hex) == 40 ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, bin} -> {ref, bin}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  # --- Internal: writing ---

  defp format_ref_value({:symbolic, target}), do: "ref: #{target}\n"

  defp format_ref_value(sha) when byte_size(sha) == 20,
    do: Base.encode16(sha, case: :lower) <> "\n"

  # --- Internal: listing ---

  defp list_loose_refs(root, prefix) do
    dir = Path.join(root, prefix)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full_path = Path.join(dir, entry)
          ref_name = prefix <> entry

          if File.dir?(full_path) do
            list_loose_refs(root, ref_name <> "/")
          else
            case File.read(full_path) do
              {:ok, content} ->
                case parse_ref_content(String.trim_trailing(content, "\n")) do
                  {:ok, value} -> [{ref_name, value}]
                  {:error, _} -> []
                end

              _ ->
                []
            end
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp list_packed_refs(root, prefix) do
    packed_path = Path.join(root, "packed-refs")

    case File.read(packed_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case parse_packed_line(line) do
            {ref, sha} when is_binary(sha) ->
              if String.starts_with?(ref, prefix), do: [{ref, sha}], else: []

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end
end

defimpl Exgit.RefStore, for: Exgit.RefStore.Disk do
  def read(store, ref), do: Exgit.RefStore.Disk.read_ref(store, ref)
  def resolve(store, ref), do: Exgit.RefStore.Disk.resolve_ref(store, ref)

  def write(store, ref, value, opts) do
    case Exgit.RefStore.Disk.write_ref(store, ref, value, opts) do
      :ok -> {:ok, store}
      error -> error
    end
  end

  def delete(store, ref) do
    case Exgit.RefStore.Disk.delete_ref(store, ref) do
      :ok -> {:ok, store}
      error -> error
    end
  end

  def list(store, prefix), do: Exgit.RefStore.Disk.list_refs(store, prefix)
end
