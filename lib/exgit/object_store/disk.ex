defmodule Exgit.ObjectStore.Disk do
  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: Path.t()}

  @spec new(Path.t()) :: t()
  def new(root), do: %__MODULE__{root: root}

  # --- Internal (used by Transport.File for direct disk access) ---

  @spec get_object(t(), binary()) :: {:ok, Exgit.Object.t()} | {:error, :not_found | term()}
  def get_object(%__MODULE__{root: root}, sha) when byte_size(sha) == 20 do
    hex = Base.encode16(sha, case: :lower)
    <<prefix::binary-size(2), rest::binary>> = hex
    path = Path.join([root, "objects", prefix, rest])

    case File.read(path) do
      {:ok, compressed} ->
        raw = :zlib.uncompress(compressed)

        with :ok <- verify_sha(raw, sha),
             {:ok, obj} <- parse_loose_object(raw) do
          {:ok, obj}
        end

      {:error, :enoent} ->
        get_from_packs(root, sha)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Git objects are content-addressed: the on-disk (uncompressed) bytes
  # hash to the sha the caller requested. Verify this on read so bit-rot
  # or tampering is caught, not silently returned as "valid" data.
  defp verify_sha(raw, expected_sha) do
    actual = :crypto.hash(:sha, raw)

    if actual == expected_sha,
      do: :ok,
      else: {:error, {:sha_mismatch, expected_sha}}
  end

  @spec put_object(t(), Exgit.Object.t()) :: {:ok, binary()} | {:error, term()}
  def put_object(%__MODULE__{root: root}, object) do
    {sha, raw} = object_raw(object)
    hex = Base.encode16(sha, case: :lower)
    <<prefix::binary-size(2), rest::binary>> = hex
    dir = Path.join([root, "objects", prefix])
    path = Path.join(dir, rest)

    if File.exists?(path) do
      {:ok, sha}
    else
      with :ok <- File.mkdir_p(dir) do
        compressed = :zlib.compress(raw)
        tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

        case atomic_write(tmp, compressed, path) do
          :ok -> {:ok, sha}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # Write content to `tmp`, fsync it, then rename to `path`. The rename
  # on POSIX is atomic; the fsync before it guarantees durability of
  # the content bytes before the directory entry swings to point at
  # them. If anything fails, tmp is cleaned up.
  defp atomic_write(tmp, content, path) do
    case :file.open(tmp, [:write, :raw, :binary]) do
      {:ok, io} ->
        result =
          with :ok <- :file.write(io, content),
               :ok <- :file.sync(io) do
            :ok
          end

        _ = :file.close(io)

        case result do
          :ok ->
            case File.rename(tmp, path) do
              :ok ->
                :ok

              {:error, reason} ->
                _ = File.rm(tmp)
                {:error, reason}
            end

          {:error, reason} ->
            _ = File.rm(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec has_object?(t(), binary()) :: boolean()
  def has_object?(%__MODULE__{root: root} = _store, sha) when byte_size(sha) == 20 do
    hex = Base.encode16(sha, case: :lower)
    <<prefix::binary-size(2), rest::binary>> = hex
    File.exists?(Path.join([root, "objects", prefix, rest])) or has_in_packs?(root, sha)
  end

  @spec delete_object(t(), binary()) :: :ok | {:error, :not_found}
  def delete_object(%__MODULE__{root: root}, sha) when byte_size(sha) == 20 do
    hex = Base.encode16(sha, case: :lower)
    <<prefix::binary-size(2), rest::binary>> = hex
    path = Path.join([root, "objects", prefix, rest])

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
    end
  end

  @spec list_objects(t()) :: [binary()]
  def list_objects(%__MODULE__{root: root}) do
    objects_dir = Path.join(root, "objects")

    case File.ls(objects_dir) do
      {:ok, prefixes} ->
        prefixes
        |> Enum.filter(&(byte_size(&1) == 2 and hex?(&1)))
        |> Enum.flat_map(fn prefix ->
          case File.ls(Path.join(objects_dir, prefix)) do
            {:ok, files} ->
              Enum.flat_map(files, fn rest ->
                case Base.decode16(prefix <> rest, case: :lower) do
                  {:ok, sha} -> [sha]
                  :error -> []
                end
              end)

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # --- Helpers ---

  defp object_raw(object) do
    type_str = Exgit.Object.type_string(object)
    content = Exgit.Object.encode(object) |> IO.iodata_to_binary()
    header = [type_str, ?\s, Integer.to_string(byte_size(content)), 0]
    raw = IO.iodata_to_binary([header, content])
    sha = :crypto.hash(:sha, raw)
    {sha, raw}
  end

  defp parse_loose_object(raw) do
    case :binary.match(raw, <<0>>) do
      {pos, 1} ->
        <<header::binary-size(pos), 0, content::binary>> = raw

        case String.split(header, " ", parts: 2) do
          [type_str, _size_str] ->
            type = type_atom(type_str)
            Exgit.Object.decode(type, content)

          _ ->
            {:error, :malformed_object_header}
        end

      :nomatch ->
        {:error, :malformed_object}
    end
  end

  defp type_atom("blob"), do: :blob
  defp type_atom("tree"), do: :tree
  defp type_atom("commit"), do: :commit
  defp type_atom("tag"), do: :tag

  defp hex?(<<a, b>>) do
    hex_char?(a) and hex_char?(b)
  end

  defp hex?(_), do: false

  defp hex_char?(c) when c in ?0..?9, do: true
  defp hex_char?(c) when c in ?a..?f, do: true
  defp hex_char?(_), do: false

  defp get_from_packs(root, sha) do
    pack_dir = Path.join([root, "objects", "pack"])

    case File.ls(pack_dir) do
      {:ok, files} ->
        idx_files = Enum.filter(files, &String.ends_with?(&1, ".idx"))
        find_in_packs(pack_dir, idx_files, sha)

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp find_in_packs(_dir, [], _sha), do: {:error, :not_found}

  defp find_in_packs(dir, [idx_file | rest], sha) do
    idx_path = Path.join(dir, idx_file)
    pack_file = String.replace_suffix(idx_file, ".idx", ".pack")
    pack_path = Path.join(dir, pack_file)

    with {:ok, idx_data} <- File.read(idx_path),
         {:ok, offset} <- Exgit.Pack.Index.lookup(idx_data, sha),
         {:ok, pack_data} <- File.read(pack_path) do
      case Exgit.Pack.Reader.parse_at(pack_data, offset) do
        {:ok, {type, ^sha, content}} -> Exgit.Object.decode(type, content)
        _ -> find_in_packs(dir, rest, sha)
      end
    else
      _ -> find_in_packs(dir, rest, sha)
    end
  end

  defp has_in_packs?(root, sha) do
    pack_dir = Path.join([root, "objects", "pack"])

    case File.ls(pack_dir) do
      {:ok, files} ->
        Enum.any?(files, fn file ->
          if String.ends_with?(file, ".idx") do
            case File.read(Path.join(pack_dir, file)) do
              {:ok, idx_data} -> Exgit.Pack.Index.lookup(idx_data, sha) != :error
              _ -> false
            end
          else
            false
          end
        end)

      _ ->
        false
    end
  end
end

defimpl Exgit.ObjectStore, for: Exgit.ObjectStore.Disk do
  alias Exgit.ObjectStore.Disk
  alias Exgit.Telemetry

  def get(store, sha) do
    Telemetry.span(
      [:exgit, :object_store, :get],
      %{store: :disk, sha: sha},
      fn ->
        case Disk.get_object(store, sha) do
          {:ok, _} = ok -> {:span, ok, %{hit?: true}}
          other -> {:span, other, %{hit?: false}}
        end
      end
    )
  end

  def put(store, object) do
    Telemetry.span(
      [:exgit, :object_store, :put],
      %{store: :disk},
      fn ->
        case Disk.put_object(store, object) do
          {:ok, sha} -> {:span, {:ok, sha, store}, %{sha: sha}}
          error -> {:span, error, %{}}
        end
      end
    )
  end

  def has?(store, sha) do
    Telemetry.span(
      [:exgit, :object_store, :has?],
      %{store: :disk, sha: sha},
      fn ->
        present? = Disk.has_object?(store, sha)
        {:span, present?, %{present?: present?}}
      end
    )
  end

  def import_objects(store, raw_objects) do
    for {type, _sha, content} <- raw_objects do
      {:ok, obj} = Exgit.Object.decode(type, content)
      Disk.put_object(store, obj)
    end

    {:ok, store}
  end
end
