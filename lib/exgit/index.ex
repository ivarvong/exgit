defmodule Exgit.Index do
  @moduledoc """
  Parser for git's on-disk index format (`.git/index`).

  Supports index versions **2 and 3**. Version 4 (name-prefix compression)
  is explicitly rejected rather than silently misparsed — see
  [gitformat-index(5)](https://git-scm.com/docs/gitformat-index).

  All parse errors are returned as `{:error, _}`; malformed inputs never
  raise.
  """

  alias Exgit.Index.Entry

  defstruct version: 2, entries: []

  @type t :: %__MODULE__{version: 2 | 3, entries: [Entry.t()]}

  @signature "DIRC"

  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, data} -> parse(data)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(<<@signature, version::32, count::32, rest::binary>>) when version in [2, 3] do
    case parse_entries(rest, count, []) do
      {:ok, entries, _rest} ->
        {:ok, %__MODULE__{version: version, entries: Enum.reverse(entries)}}

      {:error, _} = err ->
        err
    end
  end

  def parse(<<@signature, version::32, _::binary>>),
    do: {:error, {:unsupported_version, version}}

  def parse(_), do: {:error, :invalid_index}

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
