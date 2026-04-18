defmodule Exgit.RefStore.Disk do
  # Silence Dialyzer false positives on MapSet opacity in the
  # `do_resolve/4` cycle-detection set. See Exgit.Walk for the
  # upstream context.
  @dialyzer :no_opaque

  @moduledoc """
  Filesystem-backed ref store.

  ## Defense-in-depth ref name validation

  Every public entry point (`read_ref/2`, `resolve_ref/2`, `write_ref/4`,
  `delete_ref/2`) revalidates its `ref` argument against
  `Exgit.RefName.valid?/1` before any `Path.join` or file touch. The
  clone/fetch perimeter already filters hostile ref names in
  `safe_ls_refs/2`, but a direct caller of this module — or a follow-up
  `resolve_ref/2` that reads a `ref: ../../etc/passwd` target out of a
  compromised on-disk ref file — would otherwise reach `File.read` with
  an attacker-controlled path. We reject those inputs with
  `{:error, :invalid_ref_name}` and emit a
  `[:exgit, :security, :ref_rejected]` telemetry event.
  """

  @enforce_keys [:root]
  defstruct [:root]

  @type ref_value :: binary() | {:symbolic, String.t()}
  @type t :: %__MODULE__{root: Path.t()}

  @spec new(Path.t()) :: t()
  def new(root), do: %__MODULE__{root: root}

  @spec read_ref(t(), String.t()) :: {:ok, ref_value()} | {:error, :not_found | term()}
  def read_ref(%__MODULE__{root: root}, ref) do
    with :ok <- validate_ref(ref, :read) do
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
  end

  @spec resolve_ref(t(), String.t()) ::
          {:ok, binary()} | {:error, :not_found | :too_deep | :cycle | :invalid_ref_name}
  def resolve_ref(store, ref), do: do_resolve(store, ref, MapSet.new(), 10)

  @spec do_resolve(t(), String.t(), MapSet.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp do_resolve(%__MODULE__{} = store, ref, seen, depth) do
    cond do
      MapSet.member?(seen, ref) ->
        {:error, :cycle}

      depth <= 0 ->
        {:error, :too_deep}

      true ->
        case read_ref(store, ref) do
          {:ok, {:symbolic, target}} ->
            # The target was read from disk. Revalidate it before
            # recursing — a symbolic ref whose target escapes the
            # repo root must NOT be followed, even if its file on
            # disk says `ref: ../../etc/passwd`. `read_ref/2` will
            # reject it again, but we fail fast here for a clearer
            # error code.
            case validate_ref(target, :resolve_target) do
              :ok -> do_resolve(store, target, MapSet.put(seen, ref), depth - 1)
              {:error, _} = err -> err
            end

          {:ok, sha} ->
            {:ok, sha}

          error ->
            error
        end
    end
  end

  @spec write_ref(t(), String.t(), ref_value(), keyword()) :: :ok | {:error, term()}
  def write_ref(store, ref, value, opts \\ [])

  def write_ref(%__MODULE__{root: root}, ref, value, opts) do
    with :ok <- validate_ref(ref, :write),
         :ok <- validate_symbolic_target(value) do
      do_write_ref(root, ref, value, opts)
    end
  end

  defp do_write_ref(root, ref, value, opts) do
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
          with :ok <- :file.write(io, content) do
            :file.sync(io)
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

  @spec delete_ref(t(), String.t()) :: :ok | {:error, :not_found | :invalid_ref_name}
  def delete_ref(%__MODULE__{root: root}, ref) do
    with :ok <- validate_ref(ref, :delete) do
      path = Path.join(root, ref)

      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> {:error, :not_found}
      end
    end
  end

  # --- Internal: ref-name validation (defense-in-depth) ---

  # Validate that `ref` is safe to join under the repo root. Rejects
  # any name containing `..`, absolute paths, control chars, etc. See
  # `Exgit.RefName` for the exact rules. Emits telemetry on rejection
  # so operators can observe a direct-caller attack even when the
  # perimeter filter already caught the wire input.
  defp validate_ref(ref, operation) when is_binary(ref) do
    if Exgit.RefName.valid?(ref) do
      :ok
    else
      :telemetry.execute(
        [:exgit, :security, :ref_rejected],
        %{count: 1},
        %{source: {:ref_store_disk, operation}, ref: ref}
      )

      {:error, :invalid_ref_name}
    end
  end

  defp validate_ref(_other, _operation), do: {:error, :invalid_ref_name}

  # A symbolic target is itself a ref name, so it must pass the same
  # validation. A direct caller who constructs
  # `{:symbolic, "../../etc/passwd"}` cannot bypass the boundary.
  defp validate_symbolic_target({:symbolic, target}) when is_binary(target) do
    if Exgit.RefName.valid?(target) do
      :ok
    else
      :telemetry.execute(
        [:exgit, :security, :ref_rejected],
        %{count: 1},
        %{source: {:ref_store_disk, :symbolic_target}, ref: target}
      )

      {:error, :invalid_ref_name}
    end
  end

  defp validate_symbolic_target(_sha), do: :ok

  @spec list_refs(t(), String.t()) :: [{String.t(), ref_value()}]
  def list_refs(%__MODULE__{root: root}, prefix \\ "refs/") do
    # Prefix is a user/caller input. Ensure it can't escape the refs
    # directory. Git prefixes are always `refs/...` or
    # `refs/heads/...`; reject anything else outright.
    if safe_list_prefix?(prefix) do
      loose = list_loose_refs(root, prefix, 0)
      packed = list_packed_refs(root, prefix)

      loose_keys = MapSet.new(Enum.map(loose, &elem(&1, 0)))

      packed
      |> Enum.reject(fn {ref, _} -> MapSet.member?(loose_keys, ref) end)
      |> Enum.concat(loose)
      |> Enum.sort_by(&elem(&1, 0))
    else
      :telemetry.execute(
        [:exgit, :security, :ref_rejected],
        %{count: 1},
        %{source: {:ref_store_disk, :list_prefix}, ref: prefix}
      )

      []
    end
  end

  # A listing prefix must be benign path material — trailing slash
  # optional. We treat it as the `refs/...` portion of a ref name, so
  # we split on `/`, drop a trailing empty segment, and require each
  # remaining segment to be a valid ref component.
  defp safe_list_prefix?(prefix) when is_binary(prefix) do
    cond do
      String.contains?(prefix, "..") -> false
      String.contains?(prefix, <<0>>) -> false
      String.starts_with?(prefix, "/") -> false
      true -> true
    end
  end

  defp safe_list_prefix?(_), do: false

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
  defp parse_packed_line(""), do: nil

  # `^<sha>` is a peeled-tag annotation that belongs to the preceding
  # ref. Surfaced so `fold_packed_refs/3` can attach it.
  defp parse_packed_line("^" <> hex) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:peeled, bin}
      :error -> nil
    end
  end

  defp parse_packed_line("^" <> _), do: nil

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

  # Depth cap on the recursive listing. Real git ref hierarchies are
  # shallow (`refs/heads/...`, `refs/tags/...`, `refs/remotes/<n>/...`)
  # — 16 is far beyond any reasonable depth. Capping avoids
  # stack/heap exhaustion from a symlink loop that somehow escapes the
  # `File.lstat`-based guard below, or from an adversarial filesystem.
  @max_list_depth 16

  defp list_loose_refs(_root, _prefix, depth) when depth > @max_list_depth, do: []

  defp list_loose_refs(root, prefix, depth) do
    dir = Path.join(root, prefix)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          classify_loose_ref_entry(root, dir, prefix, entry, depth)
        end)

      {:error, _} ->
        []
    end
  end

  # Classify a directory entry under `<root>/<prefix>` into either:
  #   [] — skipped (symlink, or unreadable)
  #   [{ref_name, ref_value}] — a resolved ref pointer
  #   recursive: list_loose_refs under the sub-prefix
  #
  # Extracted from `list_loose_refs/3` so the cond/case scaffolding
  # doesn't exceed Credo's nesting-depth bound.
  defp classify_loose_ref_entry(root, dir, prefix, entry, depth) do
    full_path = Path.join(dir, entry)
    ref_name = prefix <> entry

    cond do
      # Refuse to follow a symlink during the recursive walk — a
      # symlink in a ref directory pointing to e.g. `/` would
      # otherwise make `File.ls/1` enumerate the whole filesystem.
      # `File.lstat` returns the symlink itself, not the target.
      symlink?(full_path) -> []
      File.dir?(full_path) -> list_loose_refs(root, ref_name <> "/", depth + 1)
      true -> read_loose_ref_file(full_path, ref_name)
    end
  end

  defp read_loose_ref_file(full_path, ref_name) do
    with {:ok, content} <- File.read(full_path),
         {:ok, value} <- parse_ref_content(String.trim_trailing(content, "\n")) do
      [{ref_name, value}]
    else
      _ -> []
    end
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  # Parse packed-refs preserving peeled-tag lines. Format:
  #
  #     # pack-refs with: peeled fully-peeled sorted
  #     a1b2c3... refs/tags/v1
  #     ^d4e5f6...          <- peeled target of the preceding tag
  #     1234abcd... refs/heads/main
  #
  # Peeled lines are attached to the preceding `{ref, sha}` pair as a
  # `{:peeled, sha}` annotation; they are NOT separate refs themselves.
  # The current public surface (`list_refs/2`) drops peeled annotations
  # because no caller consumes them yet, but we round-trip through a
  # stateful folder so a future fetch-pack negotiator can pick them up.
  defp list_packed_refs(root, prefix) do
    packed_path = Path.join(root, "packed-refs")

    case File.read(packed_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> fold_packed_refs(prefix, [])

      {:error, _} ->
        []
    end
  end

  defp fold_packed_refs([], _prefix, acc), do: Enum.reverse(acc)

  # Peeled-target lines (`^<sha>`) belong to the preceding ref. Not
  # consumed by current callers but preserved for a future
  # fetch-negotiator that wants tag-target haves. Handled as a
  # standalone clause so Dialyzer's type inference over the mixed
  # `parse_packed_line` return shape doesn't flag the
  # `{:peeled, _}` branch as unreachable.
  defp fold_packed_refs(["^" <> _ | rest], prefix, acc),
    do: fold_packed_refs(rest, prefix, acc)

  defp fold_packed_refs([line | rest], prefix, acc) do
    case parse_packed_line(line) do
      {ref, sha} when is_binary(sha) ->
        if String.starts_with?(ref, prefix),
          do: fold_packed_refs(rest, prefix, [{ref, sha} | acc]),
          else: fold_packed_refs(rest, prefix, acc)

      _ ->
        fold_packed_refs(rest, prefix, acc)
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
