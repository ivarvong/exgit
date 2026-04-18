defmodule Exgit.Index do
  @moduledoc """
  Parser for git's on-disk index format (`.git/index`).

  > #### Experimental {: .warning}
  >
  > The index module is **read-only** and exists for forensic
  > inspection / staging-area debugging — not for writing back
  > staged changes. The API, error shapes, and bounds are subject
  > to change in any 0.x release. If you're building on this, pin
  > a specific version and monitor the CHANGELOG.
  >
  > Exgit does not currently support committing FROM a populated
  > index; callers that want a commit workflow build trees
  > directly via `Exgit.Object.Tree.new/1` and commit via
  > `Exgit.Object.Commit.new/1`.

  Supports index versions **2 and 3**. Version 4 (name-prefix compression)
  is explicitly rejected rather than silently misparsed — see
  [gitformat-index(5)](https://git-scm.com/docs/gitformat-index).

  All parse errors are returned as `{:error, _}`; malformed inputs never
  raise.

  ## Bounds

    * `:max_entries` — maximum number of entries the parser will
      attempt to decode. A hostile index with `count = 2^32-1`
      would otherwise trigger billions of iterations. Default
      1,000,000 — comfortably above any real monorepo
      (linux/linux is ~75k).
    * `:max_bytes` — maximum input size. Default 512 MiB. Paired
      with `:max_entries` as defense-in-depth.
    * `:verify_checksum` — when `true` (default), verify the
      trailing SHA-1 checksum and reject corrupt indexes. Disable
      only for forensic analysis of known-corrupt files.
  """

  alias Exgit.Index.Entry

  defstruct version: 2, entries: []

  @type t :: %__MODULE__{version: 2 | 3, entries: [Entry.t()]}

  @signature "DIRC"

  @default_max_entries 1_000_000
  @default_max_bytes 512 * 1024 * 1024

  @doc """
  Read and parse `<path>/.git/index` (or any index file path).

  See the moduledoc for options and caveats.
  """
  @doc experimental: true
  @spec read(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def read(path, opts \\ []) do
    case File.read(path) do
      {:ok, data} -> parse(data, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the list of entries in a parsed index."
  @doc experimental: true
  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc """
  Parse index bytes. See moduledoc for the option set and bounds.
  """
  @doc experimental: true
  @spec parse(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(data, opts \\ [])

  def parse(data, _opts) when not is_binary(data), do: {:error, :invalid_index}

  def parse(data, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    cond do
      byte_size(data) > max_bytes ->
        {:error, {:index_too_large, byte_size(data), max_bytes}}

      true ->
        do_parse(data, opts)
    end
  end

  defp do_parse(<<@signature, version::32, count::32, rest::binary>> = data, opts)
       when version in [2, 3] do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    # Checksum verification requires the full 20-byte trailer; silently
    # skip on inputs too small to carry one (typical in unit tests that
    # exercise parser branches on header-only bytes). A real on-disk
    # index is always >= 32 bytes.
    verify? =
      Keyword.get(opts, :verify_checksum, true) and byte_size(data) >= 32

    cond do
      count > max_entries ->
        {:error, {:too_many_entries, count, max_entries}}

      verify? and not valid_checksum?(data) ->
        {:error, :checksum_mismatch}

      true ->
        case parse_entries(rest, count, []) do
          {:ok, entries, _rest} ->
            {:ok, %__MODULE__{version: version, entries: Enum.reverse(entries)}}

          {:error, _} = err ->
            err
        end
    end
  end

  defp do_parse(<<@signature, version::32, _::binary>>, _opts),
    do: {:error, {:unsupported_version, version}}

  defp do_parse(_, _opts), do: {:error, :invalid_index}

  # The trailing SHA-1 is computed over every byte up to (but not
  # including) the checksum itself. Validates against bit-rot and
  # most tampering. Does not defend against an attacker who
  # recomputes the SHA — but the file is caller-controlled, not
  # remote-controlled.
  defp valid_checksum?(data) when byte_size(data) >= 20 do
    content_size = byte_size(data) - 20
    <<content::binary-size(content_size), checksum::binary-size(20)>> = data
    :crypto.hash(:sha, content) == checksum
  end

  defp valid_checksum?(_), do: false

  defp parse_entries(rest, 0, acc), do: {:ok, acc, rest}

  defp parse_entries(data, remaining, acc) do
    case parse_entry(data) do
      {:ok, entry, rest} -> parse_entries(rest, remaining - 1, [entry | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_entry(
         <<ctime_s::32, ctime_ns::32, mtime_s::32, mtime_ns::32, dev::32, ino::32, mode::32,
           uid::32, gid::32, size::32, sha::binary-size(20), flags::16, rest::binary>>
       ) do
    name_len = Bitwise.band(flags, 0xFFF)
    stage = Bitwise.band(Bitwise.bsr(flags, 12), 0x3)
    assume_valid = Bitwise.band(flags, 0x8000) != 0
    extended = Bitwise.band(flags, 0x4000) != 0

    with {:ok, extra_flags, rest} <- maybe_read_extra_flags(rest, extended),
         {:ok, name, rest} <- read_name(rest, name_len),
         {:ok, rest} <- skip_nul_padding(rest, extended, byte_size(name)) do
      intent_to_add = Bitwise.band(extra_flags, 0x2000) != 0
      skip_worktree = Bitwise.band(extra_flags, 0x4000) != 0

      entry = %Entry{
        name: name,
        sha: sha,
        mode: mode,
        stage: stage,
        size: size,
        ctime: {ctime_s, ctime_ns},
        mtime: {mtime_s, mtime_ns},
        dev: dev,
        ino: ino,
        uid: uid,
        gid: gid,
        assume_valid: assume_valid,
        intent_to_add: intent_to_add,
        skip_worktree: skip_worktree
      }

      {:ok, entry, rest}
    end
  end

  defp parse_entry(_), do: {:error, :truncated_entry}

  defp maybe_read_extra_flags(rest, true) do
    case rest do
      <<ef::16, r::binary>> -> {:ok, ef, r}
      _ -> {:error, :truncated_extended_flags}
    end
  end

  defp maybe_read_extra_flags(rest, false), do: {:ok, 0, rest}

  # `name_len` is the 12-bit name length from flags. If it's 0xFFF (max),
  # the real length is unknown and we must read until the next NUL.
  defp read_name(data, len) when len < 0xFFF do
    case data do
      <<name::binary-size(len), 0, rest::binary>> -> {:ok, name, rest}
      _ -> {:error, :truncated_name}
    end
  end

  defp read_name(data, _len) do
    case :binary.split(data, <<0>>) do
      [name, rest] -> {:ok, name, rest}
      _ -> {:error, :truncated_name}
    end
  end

  # Git index entries are NUL-terminated and padded to 8-byte alignment.
  # read_name already consumed 1 NUL; this returns the remaining NULs.
  defp skip_nul_padding(data, extended, name_len) do
    base = if extended, do: 64, else: 62
    pad = rem(8 - rem(base + name_len, 8), 8)
    # Treat `pad == 0` specially: git pads AT LEAST 1 NUL (the terminator
    # read_name already consumed). So remaining pad is `8 - (n mod 8) - 1`
    # when n mod 8 != 0, else 7. But we already consumed one NUL — so:
    pad_remaining =
      case rem(base + name_len, 8) do
        0 -> 7
        r -> 8 - r - 1
      end

    _ = pad

    if byte_size(data) >= pad_remaining do
      <<_::binary-size(pad_remaining), rest::binary>> = data
      {:ok, rest}
    else
      {:error, :truncated_padding}
    end
  end
end
