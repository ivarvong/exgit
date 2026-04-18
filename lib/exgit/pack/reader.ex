defmodule Exgit.Pack.Reader do
  @moduledoc """
  Parser for git packfiles (v2 / v3).

  All decoder paths return `{:ok, _}` / `{:error, _}` tuples — no call
  on untrusted input ever raises. Memory is bounded via the
  `:max_pack_bytes`, `:max_objects`, `:max_object_bytes`, and
  `:max_resolved_bytes` options so a hostile server cannot exhaust
  the heap.

  ## Tracked inflate (`zlib_inflate_tracked/2`)

  Git packs store zlib streams concatenated with no length prefix,
  so the parser must determine exactly how many input bytes each
  stream consumed. Erlang's `:zlib` module does not expose consumed-
  input-count directly, so we detect stream completion by calling
  `:zlib.inflateEnd/1` on a fresh stream after feeding a candidate
  prefix. `inflateEnd` raises `data_error` iff the input did not
  include a proper end-of-stream marker + adler32, so catching
  that raise gives a clean succeed-or-raise completeness predicate.

  Implementation structure:

    1. **Phase 1 — verified full inflate.** Open a zlib stream, feed
       the upper-bounded slice through `:zlib.safeInflate/2`, drain
       all output. Verify the total output bytes equal what the pack
       header declared (`expected_size`). `safeInflate` bounds output
       per call, so a zip-bomb input cannot exhaust the heap.
    2. **Phase 2 — bisect for the exact boundary.** Binary-search
       the smallest prefix length whose `prefix_complete?/2` returns
       true. `prefix_complete?/2` opens a fresh stream, feeds the
       prefix via `safeInflate` (never `:zlib.uncompress`, which
       raises on malformed input), then tries `inflateEnd` and
       catches the raise. Output from the phase-2 probes is
       discarded — they're only testing the end-of-stream marker.

  `prefix_complete?/2` is monotone non-decreasing past the real
  boundary (once the stream is complete, all longer prefixes are
  also "complete" from zlib's perspective — it consumes up to the
  end marker and ignores trailing input), so the binary search is
  correct regardless of input shape. No hostile construction can
  desync the search.

  Previous implementations used `:zlib.uncompress/1` as the probe,
  which raises on malformed input and (worse) allocates the full
  decompressed result on every probe. `safeInflate` + `inflateEnd`
  never raises across the API boundary and bounds per-probe output.
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

  # Default cap on total resolved-object bytes held in memory during
  # parse. A hostile pack can fit inside `:max_pack_bytes` (2 GiB
  # default) but expand to many times that via lots of small
  # OFS_DELTA chains; without this cap, `resolved` + `by_sha` grow
  # unbounded. 500 MiB is enough for any legitimate pack we've seen
  # in the wild; callers with unusual needs override.
  @default_max_resolved_bytes 500 * 1024 * 1024

  defp parse_objects(pack, offset, count, store, opts) do
    max_obj_bytes = Keyword.get(opts, :max_object_bytes, 100 * 1024 * 1024)
    max_resolved = Keyword.get(opts, :max_resolved_bytes, @default_max_resolved_bytes)

    parse_loop(pack, offset, count, store, %{}, %{}, [], %{
      max_obj_bytes: max_obj_bytes,
      max_resolved_bytes: max_resolved,
      resolved_bytes: 0
    })
  end

  defp parse_loop(_pack, _offset, 0, _store, _resolved, _by_sha, acc, _limits),
    do: {:ok, Enum.reverse(acc)}

  defp parse_loop(pack, offset, remaining, store, resolved, by_sha, acc, _limits)
       when offset >= byte_size(pack) do
    _ = {remaining, store, resolved, by_sha, acc}
    {:error, :unexpected_end_of_pack}
  end

  defp parse_loop(pack, offset, remaining, store, resolved, by_sha, acc, limits) do
    obj_start = offset
    from_here = binary_part(pack, offset, byte_size(pack) - offset)

    with {:ok, type_code, obj_size, after_header, header_len} <-
           safe_decode_type_size(from_here),
         :ok <- check_object_size(obj_size, limits.max_obj_bytes) do
      case parse_one(type_code, after_header, obj_size, obj_start, store, resolved, by_sha) do
        {:ok, type_atom, sha, content, extra_consumed} ->
          new_resolved_bytes = limits.resolved_bytes + byte_size(content)

          case check_resolved_bytes(new_resolved_bytes, limits.max_resolved_bytes) do
            :ok ->
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
                %{limits | resolved_bytes: new_resolved_bytes}
              )

            {:error, _} = err ->
              err
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp check_object_size(size, max) when size > max,
    do: {:error, {:object_too_large, size, max}}

  defp check_object_size(_, _), do: :ok

  defp check_resolved_bytes(n, max) when n > max,
    do: {:error, {:resolved_too_large, n, max}}

  defp check_resolved_bytes(_, _), do: :ok

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
    # `Delta.apply/2` is spec'd to return `{:ok, _} | {:error, _}`;
    # no extra fallback clause is needed (Dialyzer flags it as
    # dead). We keep the `rescue` as defense-in-depth in case a
    # future Delta implementation raises on a programming error.
    Delta.apply(base, delta)
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
  # One-pass zlib inflate with tracked consumption.
  # ------------------------------------------------------------------
  #
  # Packs store zlib streams back-to-back with no explicit
  # compressed-length prefix. We must determine the exact number of
  # input bytes consumed so the next object starts at the right offset.
  #
  # ## Why this is subtle
  #
  # `:zlib.safeInflate/2`'s return tag (`:continue` vs `:finished`)
  # does NOT reliably distinguish "stream incomplete" from "stream
  # complete." Empirically, feeding a 2-byte prefix of a 19-byte zlib
  # stream returns `{:finished, []}` — same tag as feeding the full
  # 19 bytes. The only reliable signal for stream completion is
  # `:zlib.inflateEnd/1`, which **raises** `data_error` when the
  # input did not include a proper end-of-stream marker + adler32.
  #
  # ## Algorithm (true one-pass)
  #
  # We feed the input in two halves:
  #
  #   1. **Bulk body** — feed `upper - @tail_window` bytes in one
  #      `safeInflate` call and drain all output. After this the
  #      stream is guaranteed past the body of the zlib stream for
  #      any object whose compressed size is within `upper`.
  #      Accumulate output.
  #
  #   2. **Tail scan** — feed the remaining bytes **one at a time**,
  #      trying `inflateEnd` on a *cloned* state after each byte. The
  #      first byte-count at which `inflateEnd` succeeds is the exact
  #      zlib-stream length.
  #
  # Cloning the zlib state in Erlang is not directly supported, so
  # we use a different trick: after each byte fed during the tail
  # scan, we snapshot the decompressed-size state. When we see
  # `expected_size` bytes of output AND the stream has consumed the
  # final deflate block's end-marker, `safeInflate` transitions
  # permanently to `:finished`, and a final empty drain call
  # confirms it. We detect that transition by checking
  # `inflateEnd` on a FRESH stream re-fed with bytes 0..k — but
  # ONLY for k ∈ the tail window, capped at `@tail_window`.
  #
  # Total work: one `safeInflate` pass over the bulk, plus at most
  # `@tail_window` re-runs over the whole prefix. In practice the
  # tail window is tiny (a zlib stream ends within a few bytes of
  # the adler32 trailer), so we cap scan attempts at 64 bytes —
  # which is enough for any real stream end — and fall back to a
  # one-shot inflateEnd on the full slice if we overshoot.
  #
  # For the common case (expected_size ≈ 1..1MB, tail within 32
  # bytes of the full `upper`), this is O(object_size) bytes of
  # work, bounded port round-trips, and never calls
  # `:zlib.uncompress/1` on hostile input.

  @zlib_min 8

  @spec zlib_inflate_tracked(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  defp zlib_inflate_tracked(data, expected_size) do
    cond do
      byte_size(data) < @zlib_min ->
        {:error, :zlib_truncated}

      true ->
        # Cap the input handed to the port at a generous upper bound.
        # Passing the full remaining pack copies O(remaining_pack_size)
        # into zlib per object → O(N²) total for N objects. Slicing
        # down to `compressed_upper_bound` keeps it O(object_size).
        upper = compressed_upper_bound(expected_size, byte_size(data))

        if upper < @zlib_min do
          {:error, :zlib_bounds_invalid}
        else
          sliced = binary_part(data, 0, upper)
          do_inflate_tracked(sliced, expected_size)
        end
    end
  end

  defp do_inflate_tracked(data, expected_size) do
    # Phase 1 — open a stream, inflate everything, verify the output
    # size matches what the pack header declared.
    case safe_full_inflate(data, expected_size) do
      {:ok, content} ->
        case scan_tail_for_boundary(data, expected_size) do
          {:ok, n} -> {:ok, content, n}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # Phase 1: inflate and verify output size. Does NOT try to
  # determine consumption — that's phase 2's job.
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

  # Feed once, drain to completion. We bound drain iterations by the
  # expected output size so a zip bomb can't produce unbounded output.
  defp safe_inflate_all(z, data, acc) do
    case :zlib.safeInflate(z, data) do
      {:continue, output} -> drain_rest(z, [acc, output], 0)
      {:finished, output} -> {:ok, [acc, output]}
      {:need_dictionary, _, _} -> {:error, :zlib_need_dictionary}
    end
  rescue
    _ -> {:error, :zlib_error}
  catch
    _, _ -> {:error, :zlib_error}
  end

  @max_drain_iters 10_000

  defp drain_rest(_z, _acc, iters) when iters >= @max_drain_iters,
    do: {:error, :zlib_drain_runaway}

  defp drain_rest(z, acc, iters) do
    case :zlib.safeInflate(z, <<>>) do
      # `safeInflate` always returns an iolist for the output slot
      # (never a bare binary), so an empty-output :continue appears
      # as `[]` not `<<>>`. Dialyzer rejects the `<<>>` pattern as
      # unreachable.
      {:continue, []} -> {:ok, acc}
      {:continue, output} -> drain_rest(z, [acc, output], iters + 1)
      {:finished, output} -> {:ok, [acc, output]}
      {:need_dictionary, _, _} -> {:error, :zlib_need_dictionary}
    end
  rescue
    _ -> {:error, :zlib_error}
  catch
    _, _ -> {:error, :zlib_error}
  end

  # Phase 2: binary-search the smallest prefix length that forms a
  # complete zlib stream. Completeness is monotone non-decreasing:
  # once we find an `n` where `prefix_complete?(data, n)` is true,
  # all larger prefixes up through the slice cap are also "complete"
  # (zlib ignores trailing input when the stream already ended). So
  # a standard lower-bound bisect is correct and O(log(upper_bound))
  # probes.
  defp scan_tail_for_boundary(data, _expected_size) do
    lo = @zlib_min
    hi = byte_size(data)

    cond do
      hi < lo ->
        {:error, :zlib_bounds_invalid}

      not prefix_complete?(data, hi) ->
        # Shouldn't happen — safe_full_inflate already confirmed the
        # full slice decompresses to `expected_size`. Defensive:
        # return an error rather than loop.
        {:error, :zlib_no_boundary}

      true ->
        {:ok, bisect_complete(data, lo, hi)}
    end
  end

  defp bisect_complete(_data, lo, hi) when lo >= hi, do: lo

  defp bisect_complete(data, lo, hi) do
    mid = div(lo + hi, 2)

    if prefix_complete?(data, mid) do
      bisect_complete(data, lo, mid)
    else
      bisect_complete(data, mid + 1, hi)
    end
  end

  # Does `binary_part(data, 0, n)` form a complete zlib stream?
  # Implementation: open a fresh stream, feed the prefix via
  # safeInflate, then call inflateEnd. Raise → incomplete. Success →
  # complete.
  defp prefix_complete?(data, n) when n <= byte_size(data) do
    prefix = binary_part(data, 0, n)
    z = :zlib.open()

    try do
      :zlib.inflateInit(z)
      _ = safe_feed_all(z, prefix)

      try do
        :zlib.inflateEnd(z)
        true
      rescue
        _ -> false
      catch
        _, _ -> false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    after
      :zlib.close(z)
    end
  end

  defp prefix_complete?(_, _), do: false

  defp safe_feed_all(_z, <<>>), do: :ok

  defp safe_feed_all(z, data) do
    case :zlib.safeInflate(z, data) do
      {:continue, _} -> drain_silent(z, 0)
      {:finished, _} -> :ok
      {:need_dictionary, _, _} -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp drain_silent(_z, iters) when iters >= @max_drain_iters, do: :ok

  defp drain_silent(z, iters) do
    case :zlib.safeInflate(z, <<>>) do
      # See `drain_rest/3`: safeInflate returns iolist, not binary.
      {:continue, []} -> :ok
      {:continue, _} -> drain_silent(z, iters + 1)
      {:finished, _} -> :ok
      {:need_dictionary, _, _} -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Loose bound — we'd rather over-bound than under-bound. For any
  # expected_size N, the compressed form is at most ~N + N/16k*5 + 32.
  defp compressed_upper_bound(expected_size, data_len) do
    overhead = div(expected_size, 16_000) * 5 + 64
    bound = expected_size + overhead
    min(bound, data_len)
  end
end
