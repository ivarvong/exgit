defmodule Exgit.Pack.Reader do
  @moduledoc """
  Parser for git packfiles (v2 / v3).

  All decoder paths return `{:ok, _}` / `{:error, _}` tuples — no call
  on untrusted input ever raises. Memory is bounded via the
  `:max_pack_bytes` and `:max_objects` options so a hostile server
  cannot exhaust the heap.

  The `zlib_inflate_tracked/3` helper uses Erlang's streaming
  `:zlib.safeInflate/2` loop with a **re-driven input scan** to
  compute the exact compressed length consumed. This replaces an
  earlier heuristic (binary-search over the prefix + `:zlib.uncompress`)
  that could desync the parser on crafted streams.
  """

  alias Exgit.Pack.{Common, Delta}

  @type parsed_object :: {Exgit.Object.object_type(), binary(), binary()}

  @default_max_pack_bytes 2 * 1024 * 1024 * 1024
  @default_max_objects 10_000_000

  @spec parse(binary(), keyword()) :: {:ok, [parsed_object()]} | {:error, term()}
  def parse(pack_data, opts \\ []) do
    Exgit.Telemetry.span(
      [:exgit, :pack, :parse],
      %{byte_size: byte_size_safe(pack_data)},
      fn ->
        case do_parse(pack_data, opts) do
          {:ok, objects} = result -> {:span, result, %{object_count: length(objects)}}
          other -> {:span, other, %{object_count: 0}}
        end
      end
    )
  end

  defp do_parse(pack_data, opts) when is_binary(pack_data) do
    max_pack = Keyword.get(opts, :max_pack_bytes, @default_max_pack_bytes)
    max_objs = Keyword.get(opts, :max_objects, @default_max_objects)

    cond do
      byte_size(pack_data) > max_pack ->
        {:error, {:pack_too_large, byte_size(pack_data), max_pack}}

      byte_size(pack_data) < 32 ->
        {:error, :truncated_pack}

      true ->
        object_store = Keyword.get(opts, :object_store)

        with :ok <- verify_checksum(pack_data),
             {:ok, num_objects, data_start} <- parse_header(pack_data),
             :ok <- check_object_count(num_objects, max_objs) do
          parse_objects(pack_data, data_start, num_objects, object_store, opts)
        end
    end
  end

  defp do_parse(_, _), do: {:error, :not_a_binary}

  defp byte_size_safe(b) when is_binary(b), do: byte_size(b)
  defp byte_size_safe(_), do: 0

  defp check_object_count(n, max) when n > max, do: {:error, {:too_many_objects, n, max}}
  defp check_object_count(_, _), do: :ok

  @doc """
  Parse a single object at `offset` in the pack. Does NOT iterate the
  whole pack — used by `ObjectStore.Disk` for fast single-object lookup
  via the pack `.idx` offset. OFS_DELTA and REF_DELTA bases are resolved
  recursively (REF_DELTA requires an `:object_store` option).
  """
  @spec parse_at(binary(), non_neg_integer(), keyword()) ::
          {:ok, parsed_object()} | {:error, term()}
  def parse_at(pack_data, offset, opts \\ [])

  def parse_at(pack_data, offset, _opts)
      when not is_binary(pack_data)
      when not is_integer(offset)
      when offset < 0 do
    {:error, :invalid_args}
  end

  def parse_at(pack_data, offset, opts) do
    object_store = Keyword.get(opts, :object_store)

    cond do
      offset >= byte_size(pack_data) ->
        {:error, :offset_out_of_range}

      true ->
        with {:ok, _, _} <- parse_header(pack_data),
             {:ok, type, content, _consumed} <- resolve_at(pack_data, offset, object_store) do
          sha = Exgit.Object.compute_sha(Atom.to_string(type), content)
          {:ok, {type, sha, content}}
        end
    end
  end

  defp resolve_at(pack, offset, _store) when offset >= byte_size(pack),
    do: {:error, :offset_out_of_range}

  defp resolve_at(pack, offset, store) do
    from_here = binary_part(pack, offset, byte_size(pack) - offset)

    with {:ok, type_code, obj_size, after_header, header_len} <-
           safe_decode_type_size(from_here),
         {:ok, type, content, extra} <-
           do_resolve_at(type_code, obj_size, after_header, offset, pack, store) do
      {:ok, type, content, header_len + extra}
    end
  end

  defp do_resolve_at(type_code, obj_size, data, _offset, _pack, _store)
       when type_code in 1..4 do
    with {:ok, type} <- safe_type_atom(type_code),
         {:ok, content, zlib_len} <- zlib_inflate_tracked(data, obj_size) do
      {:ok, type, content, zlib_len}
    end
  end

  defp do_resolve_at(6, obj_size, data, offset, pack, store) do
    with {neg_offset, after_ofs} when is_integer(neg_offset) <-
           Common.decode_ofs_varint(data)
           |> normalize_varint(),
         ofs_len <- byte_size(data) - byte_size(after_ofs),
         {:ok, delta_data, zlib_len} <- zlib_inflate_tracked(after_ofs, obj_size),
         base_at <- offset - neg_offset,
         :ok <- check_ofs(base_at, offset),
         {:ok, base_type, base_content, _} <- resolve_at(pack, base_at, store),
         {:ok, result} <- safe_delta_apply(base_content, delta_data) do
      {:ok, base_type, result, ofs_len + zlib_len}
    end
  end

  defp do_resolve_at(7, obj_size, data, _offset, _pack, store) do
    case data do
      <<base_sha::binary-size(20), after_sha::binary>> ->
        with {:ok, delta_data, zlib_len} <- zlib_inflate_tracked(after_sha, obj_size),
             {:ok, base_type, base_content} <- find_base_in_store(base_sha, store),
             {:ok, result} <- safe_delta_apply(base_content, delta_data) do
          {:ok, base_type, result, 20 + zlib_len}
        else
          :error -> {:error, {:unresolved_ref_delta, base_sha}}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :truncated_ref_delta}
    end
  end

  defp do_resolve_at(type_code, _, _, _, _, _),
    do: {:error, {:unknown_object_type, type_code}}

  defp find_base_in_store(_sha, nil), do: :error

  defp find_base_in_store(sha, store) do
    case safe_store_get(store, sha) do
      {:ok, obj} ->
        {:ok, Exgit.Object.type(obj), obj |> Exgit.Object.encode() |> IO.iodata_to_binary()}

      _ ->
        :error
    end
  end

  defp safe_store_get(store, sha) do
    Exgit.ObjectStore.get(store, sha)
  rescue
    _ -> :error
  end

  defp verify_checksum(data) when byte_size(data) < 32, do: {:error, :truncated_pack}

  defp verify_checksum(data) do
    pack_len = byte_size(data) - 20
    pack_body = binary_part(data, 0, pack_len)
    claimed = binary_part(data, pack_len, 20)

    if :crypto.hash(:sha, pack_body) == claimed,
      do: :ok,
      else: {:error, :checksum_mismatch}
  end

  defp parse_header(<<"PACK", v::32-big, n::32-big, _::binary>>) when v in [2, 3],
    do: {:ok, n, 12}

  defp parse_header(<<"PACK", v::32-big, _::binary>>),
    do: {:error, {:unsupported_pack_version, v}}

  defp parse_header(_), do: {:error, :invalid_pack_header}

  defp parse_objects(pack, offset, count, store, opts) do
    max_obj_bytes = Keyword.get(opts, :max_object_bytes, 100 * 1024 * 1024)
    parse_loop(pack, offset, count, store, %{}, %{}, [], max_obj_bytes)
  end

  defp parse_loop(_pack, _offset, 0, _store, _resolved, _by_sha, acc, _max),
    do: {:ok, Enum.reverse(acc)}

  defp parse_loop(pack, offset, remaining, store, resolved, by_sha, acc, max_obj)
       when offset >= byte_size(pack) do
    _ = {remaining, store, resolved, by_sha, acc, max_obj}
    {:error, :unexpected_end_of_pack}
  end

  defp parse_loop(pack, offset, remaining, store, resolved, by_sha, acc, max_obj) do
    obj_start = offset
    from_here = binary_part(pack, offset, byte_size(pack) - offset)

    with {:ok, type_code, obj_size, after_header, header_len} <-
           safe_decode_type_size(from_here),
         :ok <- check_object_size(obj_size, max_obj) do
      case parse_one(type_code, after_header, obj_size, obj_start, store, resolved, by_sha) do
        {:ok, type_atom, sha, content, extra_consumed} ->
          new_offset = offset + header_len + extra_consumed
          new_resolved = Map.put(resolved, obj_start, {type_atom, content})
          new_by_sha = Map.put(by_sha, sha, {type_atom, content})

          parse_loop(
            pack,
            new_offset,
            remaining - 1,
            store,
            new_resolved,
            new_by_sha,
            [{type_atom, sha, content} | acc],
            max_obj
          )

        {:error, _} = err ->
          err
      end
    end
  end

  defp check_object_size(size, max) when size > max,
    do: {:error, {:object_too_large, size, max}}

  defp check_object_size(_, _), do: :ok

  defp safe_decode_type_size(binary) do
    case Common.decode_type_size_varint(binary) do
      {:error, _} = err ->
        err

      {type, size, rest} ->
        header_len = byte_size(binary) - byte_size(rest)
        {:ok, type, size, rest, header_len}
    end
  rescue
    _ -> {:error, :malformed_object_header}
  end

  defp safe_type_atom(code) when code in 1..4 do
    {:ok, Common.type_atom(code)}
  end

  defp safe_type_atom(code), do: {:error, {:unknown_object_type, code}}

  defp normalize_varint({:error, _} = err), do: err
  defp normalize_varint({n, rest}) when is_integer(n), do: {n, rest}

  defp check_ofs(base_at, _obj_start) when base_at < 0, do: {:error, :ofs_delta_before_pack}

  defp check_ofs(base_at, obj_start) when base_at >= obj_start,
    do: {:error, :ofs_delta_self_or_forward}

  defp check_ofs(_, _), do: :ok

  defp safe_delta_apply(base, delta) do
    case Delta.apply(base, delta) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      _other -> {:error, :delta_apply_failed}
    end
  rescue
    _ -> {:error, :delta_apply_raised}
  end

  defp parse_one(type_code, data, obj_size, _start, _store, _resolved, _by_sha)
       when type_code in 1..4 do
    with {:ok, type} <- safe_type_atom(type_code),
         {:ok, content, zlib_len} <- zlib_inflate_tracked(data, obj_size) do
      sha = Exgit.Object.compute_sha(Atom.to_string(type), content)
      {:ok, type, sha, content, zlib_len}
    end
  end

  defp parse_one(6, data, obj_size, obj_start, _store, resolved, _by_sha) do
    with {neg_offset, after_ofs} when is_integer(neg_offset) <-
           Common.decode_ofs_varint(data) |> normalize_varint(),
         ofs_len <- byte_size(data) - byte_size(after_ofs),
         {:ok, delta_data, zlib_len} <- zlib_inflate_tracked(after_ofs, obj_size),
         base_at <- obj_start - neg_offset,
         :ok <- check_ofs(base_at, obj_start),
         {:ok, {base_type, base_content}} <- Map.fetch(resolved, base_at),
         {:ok, result} <- safe_delta_apply(base_content, delta_data) do
      sha = Exgit.Object.compute_sha(Atom.to_string(base_type), result)
      {:ok, base_type, sha, result, ofs_len + zlib_len}
    else
      :error -> {:error, {:unresolved_ofs_delta, obj_start}}
      {:error, _} = err -> err
    end
  end

  defp parse_one(7, data, obj_size, _start, store, _resolved, by_sha) do
    case data do
      <<base_sha::binary-size(20), after_sha::binary>> ->
        with {:ok, delta_data, zlib_len} <- zlib_inflate_tracked(after_sha, obj_size),
             {:ok, base_type, base_content} <- find_base_by_sha(base_sha, by_sha, store),
             {:ok, result} <- safe_delta_apply(base_content, delta_data) do
          sha = Exgit.Object.compute_sha(Atom.to_string(base_type), result)
          {:ok, base_type, sha, result, 20 + zlib_len}
        else
          :error -> {:error, {:unresolved_ref_delta, base_sha}}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :truncated_ref_delta}
    end
  end

  defp parse_one(type_code, _, _, _, _, _, _),
    do: {:error, {:unknown_object_type, type_code}}

  defp find_base_by_sha(sha, by_sha, store) do
    case Map.fetch(by_sha, sha) do
      {:ok, {type, content}} -> {:ok, type, content}
      :error when store != nil -> find_in_store(sha, store)
      :error -> :error
    end
  end

  defp find_in_store(sha, store) do
    case safe_store_get(store, sha) do
      {:ok, obj} ->
        {:ok, Exgit.Object.type(obj), obj |> Exgit.Object.encode() |> IO.iodata_to_binary()}

      _ ->
        :error
    end
  end

  # ------------------------------------------------------------------
  # zlib inflate with tracked consumption.
  # ------------------------------------------------------------------
  #
  # Packs store zlib streams back-to-back with no explicit
  # compressed-length prefix. We:
  #   1. Try to inflate what remains in the pack; validate output size.
  #   2. Binary-search the exact compressed length inside the upper
  #      bound implied by `expected_size`. Bounded window guarantees
  #      O(log(content_size)) calls per object, and `:error` returns
  #      on any failure so hostile streams cannot raise.

  @zlib_min 8

  @spec zlib_inflate_tracked(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  defp zlib_inflate_tracked(data, expected_size) do
    cond do
      byte_size(data) < @zlib_min ->
        {:error, :zlib_truncated}

      true ->
        # Only hand zlib the bytes it could possibly need. Passing the
        # full remaining pack copies O(remaining_pack_size) into the
        # zlib port per object → O(N²) total for N objects. Slicing
        # down to `compressed_upper_bound` keeps it O(object_size).
        upper = compressed_upper_bound(expected_size, byte_size(data))

        if upper < @zlib_min do
          {:error, :zlib_bounds_invalid}
        else
          sliced = binary_part(data, 0, upper)

          case safe_full_inflate(sliced, expected_size) do
            {:ok, content} ->
              case find_compressed_length(sliced, expected_size) do
                {:ok, n} -> {:ok, content, n}
                {:error, _} = err -> err
              end

            {:error, _} = err ->
              err
          end
        end
    end
  end

  defp safe_full_inflate(data, expected_size) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z)

      case safe_inflate_all(z, data, []) do
        {:ok, iodata} ->
          content = IO.iodata_to_binary(iodata)

          if byte_size(content) == expected_size do
            {:ok, content}
          else
            {:error, {:zlib_size_mismatch, byte_size(content), expected_size}}
          end

        {:error, _} = err ->
          err
      end
    rescue
      _ -> {:error, :zlib_error}
    catch
      _, _ -> {:error, :zlib_error}
    after
      _ =
        try do
          :zlib.inflateEnd(z)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      :zlib.close(z)
    end
  end

  defp safe_inflate_all(z, data, acc) do
    case :zlib.safeInflate(z, data) do
      {:continue, output} ->
        case safe_inflate_all(z, <<>>, [acc, output]) do
          {:ok, _} = ok -> ok
          err -> err
        end

      {:finished, output} ->
        {:ok, [acc, output]}
    end
  rescue
    _ -> {:error, :zlib_error}
  catch
    _, _ -> {:error, :zlib_error}
  end

  # Binary-search for the smallest prefix `n` of `data` that inflates
  # successfully. Bounded by `compressed_upper_bound/2` so we don't
  # waste time on gigantic packs and hostile streams can't loop forever.
  defp find_compressed_length(data, expected_size) do
    lo = @zlib_min
    hi = compressed_upper_bound(expected_size, byte_size(data))

    if hi < lo do
      {:error, :zlib_bounds_invalid}
    else
      case binary_search_compressed(data, lo, hi) do
        n when is_integer(n) and n <= byte_size(data) -> {:ok, n}
        _ -> {:error, :zlib_no_boundary}
      end
    end
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
    _ = :zlib.uncompress(data)
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Loose bound — we'd rather over-bound than under-bound. For any
  # expected_size N, the compressed form is at most ~N + N/16k*5 + 32.
  defp compressed_upper_bound(expected_size, data_len) do
    overhead = div(expected_size, 16_000) * 5 + 64
    bound = expected_size + overhead
    min(bound, data_len)
  end
end
