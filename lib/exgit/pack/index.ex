defmodule Exgit.Pack.Index do
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
        for i <- 0..(total_objects - 1) do
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
    with {:ok, view} <- view(index_data) do
      lookup_in_view(view, sha)
    else
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

  defp extract_large_offsets(offsets, total, rest) do
    has_large =
      Enum.any?(0..(total - 1), fn i ->
        raw = :binary.decode_unsigned(binary_part(offsets, i * 4, 4))
        Bitwise.band(raw, 0x80000000) != 0
      end)

    if has_large do
      # Count large offsets needed
      large_count =
        Enum.count(0..(total - 1), fn i ->
          raw = :binary.decode_unsigned(binary_part(offsets, i * 4, 4))
          Bitwise.band(raw, 0x80000000) != 0
        end)

      large_size = large_count * 8
      <<large::binary-size(large_size), rest::binary>> = rest
      {large, rest}
    else
      {<<>>, rest}
    end
  end
end
