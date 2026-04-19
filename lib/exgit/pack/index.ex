defmodule Exgit.Pack.Index do
  @moduledoc """
  Pack-index (`.idx`) writer and reader for git pack-index v2.

  `write/2` produces a v2-format index (magic `\\xff\\x74\\x4f\\x63`,
  version 2) from a list of `{sha, crc32, offset}` entries and
  verifies clean with `git verify-pack`. `read/1` parses a v2
  index and returns a struct for O(log N) SHA lookups.

  v1 indexes (pre-2008 git) are not supported; v2 has been git's
  default since git 1.6.
  """

  @v2_magic <<255, 116, 79, 99>>
  @v2_version <<0, 0, 0, 2>>

  @type entry :: {sha :: binary(), crc32 :: non_neg_integer(), offset :: non_neg_integer()}

  @spec write([entry()], binary()) :: binary()
  def write(entries, pack_checksum) do
    sorted = Enum.sort_by(entries, &elem(&1, 0))

    # Fanout table: 256 entries, each a 4-byte big-endian count of objects
    # whose first byte of SHA <= index
    fanout = build_fanout(sorted)

    sha_table = Enum.map(sorted, fn {sha, _, _} -> sha end)
    crc_table = Enum.map(sorted, fn {_, crc, _} -> <<crc::32-big>> end)

    {offset_table, large_offsets} = build_offset_tables(sorted)

    idx_body =
      IO.iodata_to_binary([
        @v2_magic,
        @v2_version,
        fanout,
        sha_table,
        crc_table,
        offset_table,
        large_offsets,
        pack_checksum
      ])

    idx_checksum = :crypto.hash(:sha, idx_body)
    idx_body <> idx_checksum
  end

  @spec read(binary()) :: {:ok, [entry()], binary()} | {:error, term()}
  def read(<<@v2_magic, @v2_version, fanout_data::binary-size(1024), rest::binary>> = data) do
    total_objects = :binary.decode_unsigned(binary_part(fanout_data, 255 * 4, 4))

    sha_size = total_objects * 20
    crc_size = total_objects * 4
    offset_size = total_objects * 4

    <<shas::binary-size(sha_size), crcs::binary-size(crc_size), offsets::binary-size(offset_size),
      rest::binary>> = rest

    {large_offset_table, rest} = extract_large_offsets(offsets, total_objects, rest)

    # Pack checksum is next 20 bytes, then index checksum
    <<pack_checksum::binary-size(20), _idx_checksum::binary-size(20)>> = rest

    # Verify index checksum
    idx_body_size = byte_size(data) - 20
    <<idx_body::binary-size(idx_body_size), claimed_checksum::binary-size(20)>> = data

    if :crypto.hash(:sha, idx_body) != claimed_checksum do
      {:error, :index_checksum_mismatch}
    else
      entries =
        for i <- safe_range(total_objects) do
          sha = binary_part(shas, i * 20, 20)
          crc = :binary.decode_unsigned(binary_part(crcs, i * 4, 4))
          raw_offset = :binary.decode_unsigned(binary_part(offsets, i * 4, 4))

          offset =
            if Bitwise.band(raw_offset, 0x80000000) != 0 do
              large_idx = Bitwise.band(raw_offset, 0x7FFFFFFF)
              :binary.decode_unsigned(binary_part(large_offset_table, large_idx * 8, 8))
            else
              raw_offset
            end

          {sha, crc, offset}
        end

      {:ok, entries, pack_checksum}
    end
  end

  def read(_), do: {:error, :invalid_index_format}

  @spec lookup(binary(), binary()) :: {:ok, non_neg_integer()} | :error
  def lookup(index_data, sha) when byte_size(sha) == 20 do
    case view(index_data) do
      {:ok, view} -> lookup_in_view(view, sha)
      _ -> :error
    end
  end

  # A parsed, non-materialized view over the index: we keep subbinaries for
  # the SHA / CRC / offset tables so lookup can binary-search without
  # allocating a full Elixir list of entries.
  @typep view :: %{
           total: non_neg_integer(),
           fanout: binary(),
           shas: binary(),
           crcs: binary(),
           offsets: binary(),
           large_offsets: binary()
         }

  @spec view(binary()) :: {:ok, view()} | {:error, term()}
  defp view(<<@v2_magic, @v2_version, fanout_data::binary-size(1024), rest::binary>>) do
    total = :binary.decode_unsigned(binary_part(fanout_data, 255 * 4, 4))
    sha_size = total * 20
    crc_size = total * 4
    offset_size = total * 4

    <<shas::binary-size(sha_size), crcs::binary-size(crc_size), offsets::binary-size(offset_size),
      after_offsets::binary>> = rest

    # Large-offset table comes next in the file. We keep the whole tail
    # as a subbinary; `offset_at/2` only slices into it when a lookup
    # actually hits a large-offset entry. Scanning the full offsets
    # table eagerly (as the old code did) turned every lookup into O(N).
    {:ok,
     %{
       total: total,
       fanout: fanout_data,
       shas: shas,
       crcs: crcs,
       offsets: offsets,
       large_offsets: after_offsets
     }}
  end

  defp view(_), do: {:error, :invalid_index_format}

  defp lookup_in_view(%{total: 0}, _sha), do: :error

  defp lookup_in_view(view, <<first_byte, _::binary>> = sha) do
    {lo, hi} = fanout_range(view.fanout, first_byte)
    binary_search(view, sha, lo, hi)
  end

  # Range of candidate indices [lo, hi) whose SHAs start with `first_byte`.
  defp fanout_range(fanout, 0), do: {0, :binary.decode_unsigned(binary_part(fanout, 0, 4))}

  defp fanout_range(fanout, first_byte) do
    lo = :binary.decode_unsigned(binary_part(fanout, (first_byte - 1) * 4, 4))
    hi = :binary.decode_unsigned(binary_part(fanout, first_byte * 4, 4))
    {lo, hi}
  end

  defp binary_search(_view, _sha, lo, hi) when lo >= hi, do: :error

  defp binary_search(view, sha, lo, hi) do
    mid = div(lo + hi, 2)
    entry_sha = binary_part(view.shas, mid * 20, 20)

    cond do
      entry_sha == sha -> {:ok, offset_at(view, mid)}
      entry_sha < sha -> binary_search(view, sha, mid + 1, hi)
      true -> binary_search(view, sha, lo, mid)
    end
  end

  defp offset_at(view, idx) do
    raw = :binary.decode_unsigned(binary_part(view.offsets, idx * 4, 4))

    if Bitwise.band(raw, 0x80000000) != 0 do
      large_idx = Bitwise.band(raw, 0x7FFFFFFF)
      :binary.decode_unsigned(binary_part(view.large_offsets, large_idx * 8, 8))
    else
      raw
    end
  end

  # --- Internal ---

  defp build_fanout(sorted_entries) do
    counts =
      Enum.reduce(sorted_entries, :array.new(256, default: 0), fn {<<first_byte, _::binary>>, _,
                                                                   _},
                                                                  arr ->
        :array.set(first_byte, :array.get(first_byte, arr) + 1, arr)
      end)

    # Cumulative sum
    {fanout_list, _} =
      Enum.map_reduce(0..255, 0, fn i, running ->
        new_running = running + :array.get(i, counts)
        {<<new_running::32-big>>, new_running}
      end)

    IO.iodata_to_binary(fanout_list)
  end

  defp build_offset_tables(sorted_entries) do
    {regular, large} =
      Enum.reduce(sorted_entries, {[], []}, fn {_sha, _crc, offset}, {reg, lg} ->
        if offset >= 0x80000000 do
          large_idx = length(lg)
          marker = Bitwise.bor(0x80000000, large_idx)
          {[<<marker::32-big>> | reg], [<<offset::64-big>> | lg]}
        else
          {[<<offset::32-big>> | reg], lg}
        end
      end)

    {IO.iodata_to_binary(Enum.reverse(regular)), IO.iodata_to_binary(Enum.reverse(large))}
  end

  # A descending range (e.g. `0..-1`) is a valid Elixir term but will
  # emit deprecation warnings in 1.19+ without an explicit step. For
  # empty packs / indexes (total == 0), we want an EMPTY range, not
  # a reverse iteration. Guard explicitly.
  defp safe_range(0), do: []
  defp safe_range(n) when n > 0, do: 0..(n - 1)

  # Count the large-offset entries (top bit set) in the 32-bit
  # offsets table. Previously this function scanned the table twice:
  # once with `Enum.any?` to detect presence, then again with
  # `Enum.count` to get the count. One pass with binary pattern-
  # matching is both shorter and avoids per-iteration `binary_part`
  # allocations. `total` is redundant (the offsets binary is sized
  # `total * 4`) but kept in the signature for call-site symmetry;
  # we assert the relationship as a defense against a malformed
  # header slicing the offsets table wrong.
  defp extract_large_offsets(offsets, total, rest)
       when byte_size(offsets) == total * 4 do
    case count_large_offsets(offsets, 0) do
      0 ->
        {<<>>, rest}

      large_count ->
        large_size = large_count * 8
        <<large::binary-size(large_size), rest::binary>> = rest
        {large, rest}
    end
  end

  defp count_large_offsets(<<>>, acc), do: acc

  defp count_large_offsets(<<1::1, _::31, tail::binary>>, acc),
    do: count_large_offsets(tail, acc + 1)

  defp count_large_offsets(<<0::1, _::31, tail::binary>>, acc),
    do: count_large_offsets(tail, acc)
end
