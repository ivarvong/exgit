defmodule Exgit.Pack.Reader do
  alias Exgit.Pack.{Common, Delta}

  @type parsed_object :: {Exgit.Object.object_type(), binary(), binary()}

  @spec parse(binary(), keyword()) :: {:ok, [parsed_object()]} | {:error, term()}
  def parse(pack_data, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :pack, :parse],
      %{byte_size: byte_size(pack_data)},
      fn ->
        case do_parse(pack_data, opts) do
          {:ok, objects} = result -> {:span, result, %{object_count: length(objects)}}
          other -> {:span, other, %{object_count: 0}}
        end
      end
    )
  end

  defp do_parse(pack_data, opts) do
    object_store = Keyword.get(opts, :object_store)

    with :ok <- verify_checksum(pack_data),
         {:ok, num_objects, data_start} <- parse_header(pack_data) do
      parse_objects(pack_data, data_start, num_objects, object_store)
    end
  end

  @doc """
  Parse a single object at `offset` in the pack. Does NOT iterate the
  whole pack — used by `ObjectStore.Disk` for fast single-object lookup
  via the pack `.idx` offset. OFS_DELTA and REF_DELTA bases are resolved
  recursively (REF_DELTA requires an `:object_store` option).
  """
  @spec parse_at(binary(), non_neg_integer(), keyword()) ::
          {:ok, parsed_object()} | {:error, term()}
  def parse_at(pack_data, offset, opts \\ []) do
    object_store = Keyword.get(opts, :object_store)

    with {:ok, _, _} <- parse_header(pack_data) do
      case resolve_at(pack_data, offset, object_store) do
        {:ok, type, content, _consumed} ->
          sha = Exgit.Object.compute_sha(Atom.to_string(type), content)
          {:ok, {type, sha, content}}

        {:error, _} = err ->
          err
      end
    end
  end

  # Returns {:ok, type_atom, content, consumed_bytes_at_offset} where
  # consumed_bytes_at_offset is the number of bytes of `pack_data`
  # belonging to this object (header + compressed delta/body).
  defp resolve_at(pack, offset, store) do
    <<_::binary-size(offset), from_here::binary>> = pack
    {type_code, obj_size, after_header} = Common.decode_type_size_varint(from_here)
    header_len = byte_size(from_here) - byte_size(after_header)

    cond do
      type_code in 1..4 ->
        type = Common.type_atom(type_code)
        {content, zlib_len} = zlib_inflate_tracked(after_header, obj_size)
        {:ok, type, content, header_len + zlib_len}

      type_code == 6 ->
        {neg_offset, after_ofs} = Common.decode_ofs_varint(after_header)
        ofs_len = byte_size(after_header) - byte_size(after_ofs)
        {delta_data, zlib_len} = zlib_inflate_tracked(after_ofs, obj_size)
        base_at = offset - neg_offset

        with {:ok, base_type, base_content, _} <- resolve_at(pack, base_at, store),
             {:ok, result} <- Delta.apply(base_content, delta_data) do
          {:ok, base_type, result, header_len + ofs_len + zlib_len}
        end

      type_code == 7 ->
        <<base_sha::binary-size(20), after_sha::binary>> = after_header
        {delta_data, zlib_len} = zlib_inflate_tracked(after_sha, obj_size)

        with {:ok, base_type, base_content} <- find_base_in_store(base_sha, store),
             {:ok, result} <- Delta.apply(base_content, delta_data) do
          {:ok, base_type, result, header_len + 20 + zlib_len}
        else
          :error -> {:error, {:unresolved_ref_delta, base_sha}}
          {:error, _} = err -> err
        end

      true ->
        {:error, {:unknown_object_type, type_code}}
    end
  end

  defp find_base_in_store(_sha, nil), do: :error

  defp find_base_in_store(sha, store) do
    case Exgit.ObjectStore.get(store, sha) do
      {:ok, obj} ->
        {:ok, Exgit.Object.type(obj), obj |> Exgit.Object.encode() |> IO.iodata_to_binary()}

      _ ->
        :error
    end
  end

  defp verify_checksum(data) when byte_size(data) < 32, do: {:error, :truncated_pack}

  defp verify_checksum(data) do
    pack_len = byte_size(data) - 20
    <<pack_body::binary-size(pack_len), claimed::binary-size(20)>> = data

    if :crypto.hash(:sha, pack_body) == claimed,
      do: :ok,
      else: {:error, :checksum_mismatch}
  end

  defp parse_header(<<"PACK", v::32-big, n::32-big, _::binary>>) when v in [2, 3],
    do: {:ok, n, 12}

  defp parse_header(<<"PACK", v::32-big, _::binary>>),
    do: {:error, {:unsupported_pack_version, v}}

  defp parse_header(_), do: {:error, :invalid_pack_header}

  defp parse_objects(pack, offset, count, store) do
    # `resolved` is keyed by pack offset (for OFS_DELTA base lookup).
    # `by_sha` is an auxiliary index keyed by binary sha (for REF_DELTA
    # lookup). Maintaining both avoids the O(N^2) re-hash over the
    # resolved map that an earlier implementation suffered from.
    parse_loop(pack, offset, count, store, %{}, %{}, [])
  end

  defp parse_loop(_pack, _offset, 0, _store, _resolved, _by_sha, acc),
    do: {:ok, Enum.reverse(acc)}

  defp parse_loop(pack, offset, remaining, store, resolved, by_sha, acc) do
    obj_start = offset
    <<_::binary-size(offset), from_here::binary>> = pack
    {type_code, obj_size, after_header} = Common.decode_type_size_varint(from_here)
    header_len = byte_size(from_here) - byte_size(after_header)

    case parse_one(type_code, after_header, obj_size, obj_start, store, resolved, by_sha) do
      {:ok, type_atom, sha, content, extra_consumed} ->
        new_offset = offset + header_len + extra_consumed
        new_resolved = Map.put(resolved, obj_start, {type_atom, content})
        new_by_sha = Map.put(by_sha, sha, {type_atom, content})

        parse_loop(pack, new_offset, remaining - 1, store, new_resolved, new_by_sha, [
          {type_atom, sha, content} | acc
        ])

      {:error, _} = err ->
        err
    end
  end

  defp parse_one(type_code, data, obj_size, _start, _store, _resolved, _by_sha)
       when type_code in 1..4 do
    type = Common.type_atom(type_code)
    {content, zlib_len} = zlib_inflate_tracked(data, obj_size)
    sha = Exgit.Object.compute_sha(Atom.to_string(type), content)
    {:ok, type, sha, content, zlib_len}
  end

  defp parse_one(6, data, obj_size, obj_start, _store, resolved, _by_sha) do
    {neg_offset, after_ofs} = Common.decode_ofs_varint(data)
    ofs_len = byte_size(data) - byte_size(after_ofs)
    {delta_data, zlib_len} = zlib_inflate_tracked(after_ofs, obj_size)
    base_at = obj_start - neg_offset

    with {:ok, {base_type, base_content}} <- Map.fetch(resolved, base_at),
         {:ok, result} <- Delta.apply(base_content, delta_data) do
      sha = Exgit.Object.compute_sha(Atom.to_string(base_type), result)
      {:ok, base_type, sha, result, ofs_len + zlib_len}
    else
      :error -> {:error, {:unresolved_ofs_delta, base_at}}
      err -> err
    end
  end

  defp parse_one(7, data, obj_size, _start, store, _resolved, by_sha) do
    <<base_sha::binary-size(20), after_sha::binary>> = data
    {delta_data, zlib_len} = zlib_inflate_tracked(after_sha, obj_size)

    with {:ok, base_type, base_content} <- find_base_by_sha(base_sha, by_sha, store),
         {:ok, result} <- Delta.apply(base_content, delta_data) do
      sha = Exgit.Object.compute_sha(Atom.to_string(base_type), result)
      {:ok, base_type, sha, result, 20 + zlib_len}
    else
      :error -> {:error, {:unresolved_ref_delta, base_sha}}
      err -> err
    end
  end

  defp parse_one(type_code, _, _, _, _, _, _),
    do: {:error, {:unknown_object_type, type_code}}

  # O(1) sha→(type, content) lookup over objects already parsed in this
  # pack, falling back to the optional external object store for the
  # thin-pack case.
  defp find_base_by_sha(sha, by_sha, store) do
    case Map.fetch(by_sha, sha) do
      {:ok, {type, content}} -> {:ok, type, content}
      :error when store != nil -> find_in_store(sha, store)
      :error -> :error
    end
  end

  defp find_in_store(sha, store) do
    # Use the ObjectStore protocol rather than the internal module function.
    # Any struct that implements Exgit.ObjectStore works here.
    case Exgit.ObjectStore.get(store, sha) do
      {:ok, obj} ->
        {:ok, Exgit.Object.type(obj), obj |> Exgit.Object.encode() |> IO.iodata_to_binary()}

      _ ->
        :error
    end
  end

  # Inflate a zlib-compressed stream at the start of `data`. Returns
  # `{decompressed_content, compressed_bytes_consumed}`.
  #
  # Packfiles store zlib streams back-to-back with no explicit
  # compressed-length prefix. We take two passes:
  #
  #   1. Inflate everything into a decoded binary to validate the
  #      content and surface the output.
  #   2. Determine the exact compressed length by binary-searching
  #      inside a *bounded window* at the tail of the stream. We
  #      assume compression never inflates the payload beyond 2×; the
  #      search window is `(expected_size / min_ratio) + slack` so its
  #      size is O(content_size), not O(remaining_pack_size).
  #
  # The earlier implementation searched over the entire remaining pack,
  # making it O(pack_size) per object — this one is O(content_size).
  @spec zlib_inflate_tracked(binary(), non_neg_integer()) :: {binary(), non_neg_integer()}
  defp zlib_inflate_tracked(data, expected_size) do
    content = inflate_content(data)

    if byte_size(content) != expected_size do
      raise "pack inflate: got #{byte_size(content)} bytes, expected #{expected_size}"
    end

    compressed_len = find_compressed_length(data, expected_size)
    {content, compressed_len}
  end

  defp inflate_content(data) do
    z = :zlib.open()
    :zlib.inflateInit(z)

    try do
      {output, _} = safe_inflate_all(z, data)
      IO.iodata_to_binary(output)
    after
      _ =
        try do
          :zlib.inflateEnd(z)
        rescue
          _ -> :ok
        end

      :zlib.close(z)
    end
  end

  defp safe_inflate_all(z, data) do
    case :zlib.safeInflate(z, data) do
      {:continue, output} ->
        {more, fin} = safe_inflate_all(z, <<>>)
        {[output | more], fin}

      {:finished, output} ->
        {[output], true}
    end
  end

  # Upper bound on compressed bytes: a pathologically uncompressible
  # payload zlib-encodes to roughly size + size/16000*5 + 11 bytes. We
  # round up very generously and cap at the remaining data length.
  defp compressed_upper_bound(expected_size, data_len) do
    bound = expected_size + div(expected_size, 100) + 64
    min(bound, data_len)
  end

  # Minimum possible compressed size: 8 bytes (2 header + 4 adler + 2 tiny deflate block).
  @zlib_min_compressed 8

  defp find_compressed_length(data, expected_size) do
    lo = @zlib_min_compressed
    hi = compressed_upper_bound(expected_size, byte_size(data))
    binary_search_compressed(data, lo, hi)
  end

  defp binary_search_compressed(_data, lo, hi) when lo >= hi, do: lo

  defp binary_search_compressed(data, lo, hi) do
    mid = div(lo + hi, 2)
    prefix = binary_part(data, 0, mid)

    if try_uncompress(prefix) do
      binary_search_compressed(data, lo, mid)
    else
      binary_search_compressed(data, mid + 1, hi)
    end
  end

  defp try_uncompress(data) do
    try do
      :zlib.uncompress(data)
      true
    rescue
      _ -> false
    end
  end
end
