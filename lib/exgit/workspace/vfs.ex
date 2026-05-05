if Code.ensure_loaded?(VFS.Mountable) do
  defmodule Exgit.Workspace.VFS do
    @moduledoc """
    `VFS.Mountable` defimpl for `Exgit.Workspace`.

    Loaded only when `:vfs` is available — `Exgit.Workspace` is
    fully usable without `:vfs` for direct API access. Mounting
    a workspace into a `%VFS{}` mount table makes it interoperable
    with other backends (in-memory scratch, postgres, S3) under one
    tree.

        ws = Exgit.Workspace.open(repo, "main")
        fs = VFS.new() |> VFS.mount("/repo", ws)

        {:ok, content, fs} = VFS.read_file(fs, "/repo/lib/foo.ex")
        {:ok, fs} = VFS.write_file(fs, "/repo/lib/foo.ex", new_source)

    The mount table threads workspace state through every op, so
    cache growth from lazy fetches and `head_tree` advancement
    from writes are both visible to subsequent calls.

    ## Capabilities

    `[:read, :write, :lazy]`. We do not claim `:mkdir`: git trees
    cannot represent empty directories, so a faithful `mkdir/3`
    has no honest semantics. Writes implicitly create parents (vfs
    explicitly supports this for flat-keyed backends).

    ## Mutations through vfs vs git-aware ops

    File-shaped mutations (`write_file`, `rm`) flow through this
    impl. Git-aware ops (`Exgit.Workspace.commit/2`,
    `snapshot/1`, `restore/2`, `diff/1`, `checkout/2`) are not
    part of `VFS.Mountable` — agents reach for them on the
    workspace struct directly.
    """

    # The defimpl's own module: just a place to hang documentation.
    # Protocol implementations don't have moduledoc support directly.
  end

  defimpl VFS.Mountable, for: Exgit.Workspace do
    alias Exgit.Workspace
    alias VFS.Error
    alias VFS.Stat

    @epoch DateTime.from_unix!(0)

    # ── reads ──────────────────────────────────────────────────────────

    def exists?(%Workspace{} = ws, path) do
      p = strip_leading(VFS.Path.normalize(path))
      {boolean, ws} = Workspace.exists?(ws, p)
      {boolean, ws}
    end

    def stat(%Workspace{} = ws, path) do
      p = strip_leading(VFS.Path.normalize(path))

      case Workspace.stat(ws, p) do
        {:ok, %{type: :blob, size: size}, ws} ->
          {:ok, %Stat{type: :regular, size: size, mtime: @epoch}, ws}

        {:ok, %{type: :tree}, ws} ->
          {:ok, %Stat{type: :directory, size: 0, mtime: @epoch}, ws}

        {:error, reason} ->
          {:error, error_for(reason, path)}
      end
    end

    def readdir(%Workspace{} = ws, path) do
      p = strip_leading(VFS.Path.normalize(path))

      case Workspace.ls(ws, p) do
        {:ok, names, ws} -> {:ok, names, ws}
        {:error, reason} -> {:error, error_for(reason, path)}
      end
    end

    def stream_read(%Workspace{} = ws, path, opts) do
      p = strip_leading(VFS.Path.normalize(path))

      case Workspace.read(ws, p) do
        {:ok, data, ws} -> {:ok, slice(data, opts), ws}
        {:error, reason} -> {:error, error_for(reason, path)}
      end
    end

    def walk(%Workspace{} = ws, root, opts) do
      p = strip_leading(VFS.Path.normalize(root))
      max_depth = Keyword.get(opts, :max_depth, :infinity)
      include_dirs = Keyword.get(opts, :include_dirs, false)

      ws
      |> Workspace.walk()
      |> Stream.flat_map(fn {file_path, _sha} ->
        cond do
          not under?(file_path, p) -> []
          beyond_depth?(file_path, p, max_depth) -> []
          true -> [{"/" <> file_path, blob_stat()}]
        end
      end)
      |> maybe_with_dirs(p, include_dirs, max_depth)
    end

    # ── eager prefetch ────────────────────────────────────────────────

    def materialize(%Workspace{} = ws, _opts) do
      case Workspace.materialize(ws) do
        {:ok, ws} -> {:ok, ws}
        {:error, reason} -> {:error, Error.new(:eio, message: inspect(reason))}
      end
    end

    # ── mutations ─────────────────────────────────────────────────────

    def write_file(%Workspace{} = ws, path, content, _opts) do
      p = strip_leading(VFS.Path.normalize(path))

      case Workspace.write(ws, p, content) do
        {:ok, ws} -> {:ok, ws}
        {:error, reason} -> {:error, error_for(reason, path)}
      end
    end

    def mkdir(_ws, path, _opts) do
      {:error,
       Error.new(:enotsup, path: path, message: "git trees cannot store empty directories")}
    end

    def rm(%Workspace{} = ws, path, opts) do
      p = strip_leading(VFS.Path.normalize(path))
      recursive = Keyword.get(opts, :recursive, false)

      case Workspace.rm(ws, p, recursive: recursive) do
        {:ok, ws} -> {:ok, ws}
        {:error, reason} -> {:error, error_for(reason, path)}
      end
    end

    # ── introspection ─────────────────────────────────────────────────

    def capabilities(_), do: MapSet.new([:read, :write, :lazy])

    # ── helpers ───────────────────────────────────────────────────────

    defp strip_leading("/"), do: ""
    defp strip_leading("/" <> rest), do: rest
    defp strip_leading(other), do: other

    defp blob_stat, do: %Stat{type: :regular, size: 0, mtime: @epoch}

    defp under?(_file_path, ""), do: true

    defp under?(file_path, prefix),
      do: file_path == prefix or String.starts_with?(file_path, prefix <> "/")

    defp beyond_depth?(_file_path, _prefix, :infinity), do: false

    defp beyond_depth?(file_path, prefix, max_depth) when is_integer(max_depth) do
      depth_under(file_path, prefix) > max_depth
    end

    defp depth_under(file_path, ""), do: file_path |> String.split("/") |> length()

    defp depth_under(file_path, prefix) do
      rest = String.replace_prefix(file_path, prefix <> "/", "")
      rest |> String.split("/") |> length()
    end

    defp maybe_with_dirs(stream, _prefix, false, _max_depth), do: stream

    defp maybe_with_dirs(stream, prefix, true, max_depth) do
      # Materialize dirs by collecting unique parent paths from the
      # file stream. This forces enumeration but `walk` semantics in
      # vfs already permit a list-shaped result; the protocol only
      # requires Enumerable.t/0.
      Stream.transform(stream, MapSet.new(), fn
        {file_path, _stat} = entry, seen ->
          dirs = parent_dirs(file_path, prefix, max_depth)
          new_dirs = Enum.reject(dirs, &MapSet.member?(seen, &1))
          new_seen = Enum.reduce(new_dirs, seen, &MapSet.put(&2, &1))
          dir_entries = Enum.map(new_dirs, &{&1, %Stat{type: :directory, size: 0, mtime: @epoch}})
          {dir_entries ++ [entry], new_seen}
      end)
    end

    defp parent_dirs(file_path, prefix, max_depth) do
      "/" <> rest = file_path
      parts = String.split(rest, "/")
      # All ancestor dirs of the file (excluding the file itself).
      ancestors = parts |> Enum.drop(-1) |> ancestors_paths()
      strip_prefix = if prefix == "", do: "/", else: "/" <> prefix <> "/"

      Enum.filter(ancestors, fn dir_path ->
        cond do
          # Must be at-or-under the walk root
          dir_path == "/" <> prefix -> false
          not String.starts_with?(dir_path, strip_prefix) and prefix != "" -> false
          true -> within_depth?(dir_path, prefix, max_depth)
        end
      end)
    end

    defp ancestors_paths(parts) do
      parts
      |> Enum.scan([], fn p, acc -> acc ++ [p] end)
      |> Enum.map(fn segs -> "/" <> Enum.join(segs, "/") end)
    end

    defp within_depth?(_dir_path, _prefix, :infinity), do: true

    defp within_depth?(dir_path, prefix, max_depth) when is_integer(max_depth) do
      "/" <> rest = dir_path
      depth_under(rest, prefix) <= max_depth
    end

    # Stream slicing per vfs's stream_read options.
    defp slice(data, opts) do
      data
      |> apply_byte_range(Keyword.get(opts, :byte_range))
      |> apply_line_range(Keyword.get(opts, :line_range))
      |> chunkify(Keyword.get(opts, :chunk_size, 64 * 1024))
    end

    defp apply_byte_range(data, nil), do: data

    defp apply_byte_range(data, {start, length}) when start >= 0 and length >= 0 do
      size = byte_size(data)

      cond do
        start >= size -> ""
        start + length > size -> binary_part(data, start, size - start)
        true -> binary_part(data, start, length)
      end
    end

    defp apply_line_range(data, nil), do: data

    defp apply_line_range(data, {first, last}) when first >= 1 do
      lines = String.split(data, "\n")
      total = length(lines)
      ends_with_nl? = String.ends_with?(data, "\n")

      # If the data ends with "\n", String.split yields a trailing "".
      # We want to operate on logical lines (1..N where N is the count
      # of \n-terminated or final non-empty segments).
      logical_lines =
        if ends_with_nl? and total > 0 and List.last(lines) == "",
          do: Enum.drop(lines, -1),
          else: lines

      logical_count = length(logical_lines)

      last_idx =
        case last do
          :end -> logical_count
          n when is_integer(n) -> min(n, logical_count)
        end

      if first > logical_count do
        ""
      else
        slice = Enum.slice(logical_lines, (first - 1)..(last_idx - 1))
        joined = Enum.join(slice, "\n")
        if last == :end and ends_with_nl?, do: joined <> "\n", else: joined
      end
    end

    defp chunkify("", _chunk_size), do: []

    defp chunkify(data, chunk_size) when is_integer(chunk_size) and chunk_size > 0 do
      Stream.unfold(data, fn
        "" ->
          nil

        rest when byte_size(rest) <= chunk_size ->
          {rest, ""}

        rest ->
          <<chunk::binary-size(chunk_size), more::binary>> = rest
          {chunk, more}
      end)
    end

    # Error mapping. `path` is the ORIGINAL (pre-stripping) path so the
    # error surface to vfs callers contains absolute paths.
    defp error_for(:not_found, path), do: Error.new(:enoent, path: VFS.Path.normalize(path))
    defp error_for(:not_a_blob, path), do: Error.new(:eisdir, path: VFS.Path.normalize(path))
    defp error_for(:not_a_tree, path), do: Error.new(:enotdir, path: VFS.Path.normalize(path))
    defp error_for(:eisdir, path), do: Error.new(:eisdir, path: VFS.Path.normalize(path))
    defp error_for(:enotdir, path), do: Error.new(:enotdir, path: VFS.Path.normalize(path))

    defp error_for(:cannot_rm_root, path),
      do: Error.new(:einval, path: VFS.Path.normalize(path), message: "cannot rm /")

    defp error_for(reason, path),
      do: Error.new(:eio, path: VFS.Path.normalize(path), message: inspect(reason))
  end
end
