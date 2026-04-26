defmodule Exgit.Pack.StreamParser do
  @moduledoc """
  Forward-only, bounded-memory streaming pack parser.

  Accepts raw pack bytes incrementally via `ingest/2` and writes each
  resolved object directly to an `Exgit.ObjectStore` as it is decoded.

  ## Memory model (Phase 3+)

  | Component              | Bound                                         |
  |------------------------|-----------------------------------------------|
  | Parse buffer           | O(zlib_window) per `ingest/2` chunk           |
  | In-flight inflate      | O(one zlib output chunk, ~4 KB)               |
  | In-flight write handle | O(compressed output) — raw content never sits |
  |                        | alongside the compressed form in the heap     |
  | offset_to_sha map      | ~35 bytes × N objects                         |
  | sha_to_depth map       | ~30 bytes × N objects                         |

  For **non-delta objects** (types blob/tree/commit/tag), each decompressed
  chunk is piped immediately to the object store via
  `ObjectStore.open_write / write_chunk / close_write`. The raw content is
  never materialised in full — it flows inflate-port → write-handle → store
  one HTTP-chunk-sized piece at a time. The adler32 (for zlib boundary
  detection) and the git SHA are both computed incrementally.

  For **delta objects** (OFS_DELTA / REF_DELTA), the decompressed delta
  instructions must be held in full to call `Pack.Delta.apply/2`. These
  objects are still accumulated in `inflate_out`; the resulting resolved
  content then goes through `ObjectStore.put/2` as before.

  The compressed-buffer spike of the naive approach (`inflate_upper_bound`
  bytes must be present before inflate can start) is eliminated: the zlib
  port is opened as soon as `@zlib_min` bytes are available and fed
  incrementally on every subsequent `ingest/2`.

  ## Adversarial hardening (Phase 4)

  Every limit is enforced per-object during the streaming parse:

  * **`max_object_bytes`** — rejects any object whose declared
    uncompressed size exceeds the limit before allocating.
  * **`max_inflate_ratio`** — zip-bomb defence; if
    `uncompressed / compressed > ratio`, the object is rejected.
  * **`max_delta_depth`** — cap on delta chain length; stops an
    attacker from constructing a chain that forces O(depth) store
    fetches per object.
  * **`max_objects`** — rejects packs with an absurd object count
    header before any objects are parsed.
  * **`deadline`** — monotonic deadline (`:erlang.monotonic_time(:millisecond)`);
    `ingest/2` returns `{:error, :deadline_exceeded}` when the clock
    passes it.

  ## OFS_DELTA / REF_DELTA resolution

  Git packs guarantee that a delta's base always appears earlier in the
  pack. Each resolved object is written to the store immediately; OFS_DELTA
  looks up `pack_offset → {type, sha, depth}` in `offset_to_sha` and
  fetches from the store. REF_DELTA uses `sha_to_depth` to look up the
  base depth for chain-length tracking (defaults to 0 for objects already
  in the store from a prior fetch).

  ## SHA-1 checksum

  A rolling 20-byte delay ensures that `sha_tail` at `finalize/1` contains
  exactly the pack's trailing checksum. Verification only happens in
  `finalize/1` — not in the streaming `loop` — because `sha_tail` doesn't
  reach the correct final value until all bytes have been fed.
  """

  alias Exgit.{Object, ObjectStore}
  alias Exgit.Pack.{Common, Delta}

  # ---------------------------------------------------------------------------
  # Defaults & constants
  # ---------------------------------------------------------------------------

  @default_max_obj_bytes 100 * 1024 * 1024
  @default_max_objects 10_000_000
  @default_max_delta_depth 50
  @default_max_inflate_ratio 1_000
  # Default raw-content cache: 64 MB budget.
  # Stores {type, raw_content} keyed by sha, eliminating the
  # zlib.uncompress + Object.decode + Object.encode round-trips that make
  # delta resolution through the Memory store ~50× slower than Pack.Reader.
  @default_raw_cache_bytes 64 * 1024 * 1024
  @zlib_min 8
  @adler_window 64
  @adler_trailer 4
  @boundary_slack 8
  @max_drain_iters 10_000

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  # `current` is nil between objects. When non-nil it holds the decoded header
  # of the in-progress object PLUS the streaming inflate state.
  # `buffer[0]` is the first byte of the zlib stream whenever current != nil
  # (header bytes have already been consumed and buffer_start advanced).

  defstruct [
    :store,
    :sha_ctx,
    sha_tail: <<>>,
    phase: :pack_header,
    buffer: <<>>,
    buffer_start: 0,
    num_objects: 0,
    objects_done: 0,
    # pack_offset → {type_atom, sha, depth}
    offset_to_sha: %{},
    # sha → delta_chain_depth (for REF_DELTA depth tracking)
    sha_to_depth: %{},
    # sha → {type_atom, raw_content} — raw content cache for delta base resolution.
    # Avoids the zlib.uncompress + Object.decode + Object.encode round-trip that
    # makes delta resolution through the store prohibitively slow. Bounded to
    # raw_cache_budget bytes; once full, new entries are still inserted (overwriting
    # old ones by SHA) — the map grows up to the point where the budget was set,
    # after which we rely on the store (cold path). This is a simple approximation
    # of an LRU; a proper LRU can replace it when needed.
    raw_cache: %{},
    raw_cache_bytes: 0,
    current: nil,
    limits: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Create a new `StreamParser` state that will write objects to `store`.

  Options:
    * `:max_object_bytes`  — max inflated size of any single object (default 100 MB).
    * `:max_objects`       — max number of objects in the pack (default 10 M).
    * `:max_delta_depth`   — max delta chain depth (default 50, same as git).
    * `:max_inflate_ratio` — max uncompressed/compressed ratio; detects zip bombs
                             (default 1000×).
    * `:deadline`          — `:erlang.monotonic_time(:millisecond)` value after
                             which `ingest/2` returns `{:error, :deadline_exceeded}`.
                             `nil` (default) means no deadline.
    * `:raw_cache_bytes`   — budget in bytes for the raw-content cache used to
                             speed up delta base resolution (default 64 MB). Set
                             to 0 to disable and always go through the store.
  """
  @spec new(ObjectStore.t(), keyword()) :: t()
  def new(store, opts \\ []) do
    %__MODULE__{
      store: store,
      sha_ctx: :crypto.hash_init(:sha),
      limits: %{
        max_obj_bytes: Keyword.get(opts, :max_object_bytes, @default_max_obj_bytes),
        max_objects: Keyword.get(opts, :max_objects, @default_max_objects),
        max_delta_depth: Keyword.get(opts, :max_delta_depth, @default_max_delta_depth),
        max_inflate_ratio: Keyword.get(opts, :max_inflate_ratio, @default_max_inflate_ratio),
        deadline: Keyword.get(opts, :deadline),
        raw_cache_budget: Keyword.get(opts, :raw_cache_bytes, @default_raw_cache_bytes)
      }
    }
  end

  @doc """
  Feed a chunk of raw pack bytes into the parser.

  Objects are written to the store as they complete. Returns `{:ok,
  state}` when the chunk was processed successfully (the parser may need
  more bytes), or `{:error, reason}` on a fatal parse error.
  """
  @spec ingest(t(), binary()) :: {:ok, t()} | {:error, term()}
  def ingest(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    with :ok <- check_deadline(state.limits.deadline) do
      state = update_sha(state, bytes)
      state = %{state | buffer: state.buffer <> bytes}
      loop(state)
    end
  end

  @doc """
  Assert the parse is complete: all N objects were decoded and the pack's
  SHA-1 trailer matches. Returns `{:ok, n_objects, final_store}` or
  `{:error, reason}`.

  `final_store` is the object store after all objects have been written.
  For value-typed stores (e.g. `Memory`) this is the updated struct; for
  side-effect stores (e.g. `Disk`) it equals the original store reference.
  """
  @spec finalize(t()) :: {:ok, non_neg_integer(), ObjectStore.t()} | {:error, term()}

  # :trailer is the normal terminal state. Verify checksum here — not inside
  # loop — because sha_tail doesn't hold the correct trailing checksum until
  # ALL bytes have been fed via ingest/2.
  def finalize(%__MODULE__{
        phase: :trailer,
        sha_tail: tail,
        sha_ctx: ctx,
        objects_done: n,
        store: store
      }) do
    cond do
      byte_size(tail) < 20 ->
        {:error, :truncated_checksum}

      true ->
        claimed = binary_part(tail, 0, 20)
        computed = :crypto.hash_final(ctx)

        if claimed == computed,
          do: {:ok, n, store},
          else: {:error, :checksum_mismatch}
    end
  end

  def finalize(%__MODULE__{phase: :pack_header}), do: {:error, :incomplete_pack_header}

  def finalize(%__MODULE__{phase: {:objects, remaining}}) do
    {:error, {:incomplete_objects, remaining}}
  end

  def finalize(%__MODULE__{}), do: {:error, :incomplete}

  # ---------------------------------------------------------------------------
  # SHA-1 rolling update
  # ---------------------------------------------------------------------------
  #
  # Delay by 20 bytes so sha_tail at finalize time holds exactly the pack's
  # trailing 20-byte checksum, while sha_ctx has hashed everything before it.

  defp update_sha(%{sha_ctx: ctx, sha_tail: tail} = state, bytes) do
    all = tail <> bytes
    keep = min(20, byte_size(all))
    to_hash = binary_part(all, 0, byte_size(all) - keep)
    new_tail = binary_part(all, byte_size(all) - keep, keep)
    %{state | sha_ctx: :crypto.hash_update(ctx, to_hash), sha_tail: new_tail}
  end

  # ---------------------------------------------------------------------------
  # Deadline check
  # ---------------------------------------------------------------------------

  defp check_deadline(nil), do: :ok

  defp check_deadline(dl) do
    if :erlang.monotonic_time(:millisecond) >= dl,
      do: {:error, :deadline_exceeded},
      else: :ok
  end

  # ---------------------------------------------------------------------------
  # Main parsing loop
  # ---------------------------------------------------------------------------

  defp loop(%{phase: :pack_header, buffer: buf} = state) when byte_size(buf) >= 12 do
    case buf do
      <<"PACK", v::32-big, n::32-big, rest::binary>> when v in [2, 3] ->
        if n > state.limits.max_objects do
          {:error, {:too_many_objects, n, state.limits.max_objects}}
        else
          loop(%{state | phase: {:objects, n}, num_objects: n, buffer: rest, buffer_start: 12})
        end

      <<"PACK", v::32-big, _::binary>> ->
        {:error, {:unsupported_pack_version, v}}

      _ ->
        {:error, :invalid_pack_header}
    end
  end

  defp loop(%{phase: :pack_header} = state), do: {:ok, state}

  defp loop(%{phase: {:objects, 0}} = state), do: loop(%{state | phase: :trailer})

  defp loop(%{phase: {:objects, n}} = state) do
    case parse_next(state) do
      # Object fully stored (current = nil) — decrement and keep going.
      {:ok, %{current: nil} = new_state} ->
        loop(%{new_state | phase: {:objects, n - 1}})

      # Object in progress (current set) — preserve state, don't decrement.
      {:ok, new_state} ->
        {:ok, new_state}

      # Not enough bytes even for the header — return unchanged state.
      :need_more ->
        {:ok, state}

      {:error, _} = err ->
        err
    end
  end

  # :trailer is a wait state — remain here until finalize/1 is called.
  defp loop(%{phase: :trailer} = state), do: {:ok, state}

  # ---------------------------------------------------------------------------
  # Object parsing
  # ---------------------------------------------------------------------------

  # Resume: header already decoded, current != nil, buffer starts at zlib data.
  defp parse_next(%{current: %{} = cur} = state) do
    do_inflate(state, cur)
  end

  # Fresh object: decode the type/size varint (and ofs/ref extras).
  defp parse_next(%{current: nil, buffer: buf, buffer_start: bs} = state) do
    case decode_full_header(buf, bs) do
      {:ok, cur, remaining} ->
        header_consumed = byte_size(buf) - byte_size(remaining)

        # For non-delta objects, open a streaming write handle immediately so
        # each inflate chunk is written to the store as it arrives (Phase 3+).
        # Delta objects still accumulate inflate_out for Delta.apply.
        {cur, state2} = maybe_open_write(cur, state)

        state2 = %{state2 | buffer: remaining, buffer_start: bs + header_consumed, current: cur}

        # do_inflate always returns {:ok, updated_state} | {:error, reason}.
        # When more bytes are needed, updated_state.current is non-nil and
        # carries the open inflate port and write handle so the next ingest
        # resumes seamlessly — no re-processing from scratch.
        do_inflate(state2, cur)

      :need_more ->
        :need_more

      {:error, _} = err ->
        err
    end
  end

  # Open a streaming write handle for non-delta objects.
  #
  # Streaming writes are used for blobs and tags (type codes 3 and 4).
  # Trees and commits (type codes 1 and 2) use the traditional accumulate+put
  # path so their raw content lands in the raw_cache — they are the most
  # common delta bases and fetching them through the store (decompress +
  # Object.decode + Object.encode) is expensive enough to dominate parse time.
  #
  # Blobs are rarely delta bases in git packs, so streaming writes for them
  # are safe and reduce peak memory for large files.
  defp maybe_open_write(%{type_code: tc, expected_size: es} = cur, state)
       when tc in [3, 4] do
    # 3 = blob, 4 = tag
    type = Common.type_atom(tc)

    case ObjectStore.open_write(state.store, type, es) do
      {:ok, handle} -> {%{cur | write_handle: handle}, state}
      {:error, _} -> {cur, state}
    end
  end

  # Commits (1), trees (2), and deltas (6, 7) use traditional accumulate path.
  defp maybe_open_write(cur, state), do: {cur, state}

  # ---------------------------------------------------------------------------
  # Header decoding
  # ---------------------------------------------------------------------------

  defp decode_full_header(buf, obj_offset) do
    case safe_decode_type_size(buf) do
      {:error, _} ->
        :need_more

      {type_code, expected_size, after_ts} ->
        decode_type_extras(type_code, expected_size, after_ts, obj_offset)
    end
  end

  defp safe_decode_type_size(buf) do
    Common.decode_type_size_varint(buf)
  rescue
    _ -> {:error, :malformed_header}
  end

  defp decode_type_extras(tc, expected_size, after_ts, obj_offset) when tc in 1..4 do
    {:ok, base_current(tc, expected_size, obj_offset), after_ts}
  end

  defp decode_type_extras(6, expected_size, after_ts, obj_offset) do
    case Common.decode_ofs_varint(after_ts) do
      {:error, _} ->
        :need_more

      {neg_ofs, after_ofs} ->
        base_abs = obj_offset - neg_ofs

        if base_abs < 0 do
          {:error, :ofs_delta_before_pack}
        else
          cur = base_current(6, expected_size, obj_offset)
          {:ok, %{cur | ofs_base_offset: base_abs}, after_ofs}
        end
    end
  end

  defp decode_type_extras(7, expected_size, after_ts, obj_offset) do
    case after_ts do
      <<base_sha::binary-size(20), after_sha::binary>> ->
        cur = base_current(7, expected_size, obj_offset)
        {:ok, %{cur | ref_base_sha: base_sha}, after_sha}

      _ ->
        :need_more
    end
  end

  defp decode_type_extras(tc, _expected_size, _after_ts, _obj_offset) do
    {:error, {:unknown_object_type, tc}}
  end

  defp base_current(type_code, expected_size, obj_offset) do
    %{
      type_code: type_code,
      expected_size: expected_size,
      obj_offset: obj_offset,
      ofs_base_offset: nil,
      ref_base_sha: nil,
      # Streaming inflate state (Phase 3)
      zlib: nil,
      # used by delta objects only (Phase 3+)
      inflate_out: [],
      inflate_out_bytes: 0,
      inflate_in_bytes: 0,
      inflate_in_tail: <<>>,
      # Incremental adler32 of inflate output (Phase 3+).
      # Eliminates IO.iodata_to_binary in locate_boundary for all object types.
      inflate_adler: 1,
      # Streaming write handle (Phase 3+).
      # Non-nil for non-delta objects when the store supports open_write.
      # Nil for delta objects (they still accumulate inflate_out).
      write_handle: nil,
      # Delta chain depth (Phase 4)
      depth: 0
    }
  end

  # ---------------------------------------------------------------------------
  # Streaming inflate (Phase 3)
  # ---------------------------------------------------------------------------
  #
  # We keep a zlib port open in `current.zlib` across `ingest/2` calls.
  # On each call, ONLY new bytes (buffer[inflate_in_bytes..]) are fed to the
  # port. This bounds the per-ingest memory cost to one HTTP chunk (~4 KB)
  # rather than the full compressed object size.
  #
  # Boundary detection at completion:
  #   1. Fast path — Adler32 probe on `inflate_in_tail` (last @adler_window
  #      bytes of compressed input). Correct in all but ~2^-32 cases.
  #   2. Fallback   — bisect on `buffer[0..inflate_in_bytes]`, which is still
  #      present in the buffer (not advanced until inflation completes).
  #
  # Phase 3+ follow-up: add streaming store-write API so the inflate_out iolist
  # is flushed to the store chunk-by-chunk rather than materialised in full
  # before storing. That eliminates the O(object_size) heap spike for large
  # blobs. Requires new `open_object / write_chunk / close_object` callbacks
  # on the ObjectStore protocol.

  # do_inflate always returns {:ok, state} or {:error, reason}.
  # When more bytes are needed, the returned state has current set (non-nil)
  # with the open inflate port and write handle preserved — the loop and
  # ingest machinery can pass it straight back without losing any progress.
  defp do_inflate(%{buffer: buf, limits: limits} = state, cur) do
    available = byte_size(buf)
    already_fed = cur.inflate_in_bytes
    new_available = available - already_fed

    # Cap bytes fed per call to the compressed upper-bound of this object.
    # Without the cap, tiny objects (100 bytes) in a large buffer (34 MB)
    # would feed 34 MB to the inflate NIF — O(pack_size × num_objects) work.
    max_this_call = max(inflate_upper_bound(cur.expected_size) - already_fed, 0)
    capped_new = min(new_available, max_this_call)

    cond do
      cur.expected_size > limits.max_obj_bytes ->
        cleanup_zlib(cur.zlib)
        {:error, {:object_too_large, cur.expected_size, limits.max_obj_bytes}}

      # Output is already complete — try to find the stream boundary.
      cur.inflate_out_bytes >= cur.expected_size ->
        complete_inflate(state, cur)

      # Not enough bytes to open a zlib stream.
      already_fed == 0 and available < @zlib_min ->
        {:ok, state}

      # Nothing new within the capped window — wait for more bytes.
      capped_new == 0 ->
        {:ok, state}

      true ->
        new_data = binary_part(buf, already_fed, capped_new)
        feed_inflate(state, cur, new_data, limits)
    end
  end

  # Open the port on first feed (zlib == nil) or resume an existing one.
  defp feed_inflate(state, cur, new_data, limits) do
    {zlib, cur} =
      if cur.zlib do
        {cur.zlib, cur}
      else
        z = :zlib.open()
        :zlib.inflateInit(z)
        {z, %{cur | zlib: z}}
      end

    case safe_inflate_chunk(zlib, new_data) do
      {:ok, output_chunk} ->
        # Always work with a binary so we can compute adler32 and write_chunk.
        chunk_bin = IO.iodata_to_binary(output_chunk)
        new_out_bytes = cur.inflate_out_bytes + byte_size(chunk_bin)
        new_in_bytes = cur.inflate_in_bytes + byte_size(new_data)
        new_in_tail = update_adler_tail(cur.inflate_in_tail, new_data)
        # Adler32 is updated incrementally for ALL object types (Phase 3+).
        new_adler = :erlang.adler32(cur.inflate_adler, chunk_bin)

        # Phase 4: inflate ratio check (zip-bomb defence).
        if limits.max_inflate_ratio != nil and
             new_in_bytes > 0 and
             new_out_bytes / new_in_bytes > limits.max_inflate_ratio do
          cleanup_zlib(zlib)
          cancel_write_handle(state.store, cur.write_handle)

          {:error,
           {:inflate_ratio_exceeded, new_in_bytes, new_out_bytes, limits.max_inflate_ratio}}
        else
          # Route output to write_handle (non-delta, Phase 3+) or inflate_out (delta).
          case route_chunk(state, cur, chunk_bin) do
            {:ok, cur} ->
              cur = %{
                cur
                | zlib: zlib,
                  inflate_out_bytes: new_out_bytes,
                  inflate_in_bytes: new_in_bytes,
                  inflate_in_tail: new_in_tail,
                  inflate_adler: new_adler
              }

              state = %{state | current: cur}

              if new_out_bytes >= cur.expected_size do
                complete_inflate(state, cur)
              else
                # Return {:ok, state} with current set — the loop sees a
                # non-nil current and knows to preserve state without
                # decrementing the remaining-object count.
                {:ok, state}
              end

            {:error, _} = err ->
              cleanup_zlib(zlib)
              cancel_write_handle(state.store, cur.write_handle)
              err
          end
        end

      {:error, reason} ->
        cleanup_zlib(zlib)
        cancel_write_handle(state.store, cur.write_handle)
        {:error, {:zlib_feed_error, cur.obj_offset, reason}}
    end
  end

  # Non-delta with streaming write: pipe chunk to the write handle.
  defp route_chunk(state, %{write_handle: wh} = cur, chunk_bin) when wh != nil do
    case ObjectStore.write_chunk(state.store, wh, chunk_bin) do
      {:ok, new_handle} -> {:ok, %{cur | write_handle: new_handle}}
      {:error, _} = err -> err
    end
  end

  # Delta or fallback (no write handle): accumulate in inflate_out.
  defp route_chunk(_state, cur, chunk_bin) do
    {:ok, %{cur | inflate_out: [cur.inflate_out | chunk_bin]}}
  end

  defp cancel_write_handle(_store, nil), do: :ok
  defp cancel_write_handle(store, handle), do: ObjectStore.cancel_write(store, handle)

  # Conservative upper bound on the compressed size of an object whose
  # uncompressed size is `expected_size`. Used to cap how many bytes we feed
  # to the inflate NIF per call, preventing O(buf_size × num_objects) work.
  defp inflate_upper_bound(expected_size) do
    overhead = div(expected_size, 16_000) * 5 + 64
    expected_size + overhead
  end

  # All expected output bytes have arrived — find the exact stream boundary.
  #
  # We do NOT close the port until the boundary is confirmed. If `locate_boundary`
  # can't find the adler32 yet (it hasn't arrived in the buffer), we return
  # `:need_more` with the port still open. `do_inflate` will call us again on
  # the next ingest once more bytes are available.
  defp complete_inflate(%{buffer: buf} = state, cur) do
    case locate_boundary(buf, cur) do
      {:ok, consumed} ->
        cleanup_zlib(cur.zlib)

        # For non-delta objects with a streaming write handle: content has
        # already been written to the store chunk-by-chunk — pass nil so
        # finish_object knows to call close_write rather than decode+put.
        content =
          if cur.write_handle != nil,
            do: nil,
            else: IO.iodata_to_binary(cur.inflate_out)

        finish_object(state, %{cur | zlib: nil}, content, consumed)

      {:error, _} ->
        # Adler32 not yet in buffer — keep port open, return state with current set.
        {:ok, state}
    end
  end

  # Locate the exact end of the zlib stream.
  #
  # We trigger completion when `inflate_out_bytes >= expected_size`, which
  # means the deflate body is done — but the 4-byte Adler32 trailer may not
  # have been fed to the port yet.  To handle that, we search a window that
  # extends `@adler_trailer` bytes BEYOND `inflate_in_bytes`.
  #
  # Fast path: Adler32 bytes in the search window → `prefix_complete?` probe
  # on each candidate → first hit wins.
  # Fallback: binary-search the minimum complete prefix within the window.
  defp locate_boundary(buf, cur) do
    # inflate_adler is maintained incrementally for all object types (Phase 3+),
    # so we never need to materialise inflate_out just to compute the checksum.
    trailer = <<cur.inflate_adler::32>>

    # Extend search window past inflate_in_bytes to catch the adler32 trailer
    # in case it wasn't fed to the streaming port yet.
    search_end = min(cur.inflate_in_bytes + @boundary_slack, byte_size(buf))
    search_window = binary_part(buf, 0, search_end)

    case :binary.matches(search_window, trailer) do
      [] ->
        bisect_boundary_in_buf(buf, search_end)

      matches ->
        result =
          Enum.find_value(matches, fn {pos, 4} ->
            candidate = pos + @adler_trailer

            if candidate <= search_end and prefix_complete?(buf, candidate) do
              {:ok, candidate}
            end
          end)

        result || bisect_boundary_in_buf(buf, search_end)
    end
  end

  # Bisect over buffer[0..max_bytes] to find the smallest complete prefix.
  defp bisect_boundary_in_buf(buf, max_bytes) do
    lo = @zlib_min
    hi = min(max_bytes, byte_size(buf))

    cond do
      hi < lo -> {:error, :zlib_bounds_invalid}
      not prefix_complete?(buf, hi) -> {:error, :zlib_no_boundary}
      true -> {:ok, bisect_complete(buf, lo, hi)}
    end
  end

  # Keep only the last @adler_window bytes of compressed input seen so far.
  defp update_adler_tail(tail, new_bytes) do
    all = tail <> new_bytes
    drop = max(0, byte_size(all) - @adler_window)
    binary_part(all, drop, byte_size(all) - drop)
  end

  # Feed a chunk to the open zlib port, collecting output. Never raises.
  defp safe_inflate_chunk(z, data) do
    case :zlib.safeInflate(z, data) do
      {:continue, output} -> drain_inflate(z, [output], 0)
      {:finished, output} -> {:ok, [output]}
      {:need_dictionary, _, _} -> {:error, :zlib_need_dictionary}
    end
  rescue
    _ -> {:error, :zlib_error}
  catch
    _, _ -> {:error, :zlib_error}
  end

  defp drain_inflate(_z, _acc, iters) when iters >= @max_drain_iters,
    do: {:error, :zlib_drain_runaway}

  defp drain_inflate(z, acc, iters) do
    case :zlib.safeInflate(z, <<>>) do
      {:continue, []} -> {:ok, acc}
      {:continue, output} -> drain_inflate(z, [acc | output], iters + 1)
      {:finished, output} -> {:ok, [acc | output]}
      {:need_dictionary, _, _} -> {:error, :zlib_need_dictionary}
    end
  rescue
    _ -> {:error, :zlib_error}
  catch
    _, _ -> {:error, :zlib_error}
  end

  defp cleanup_zlib(nil), do: :ok

  defp cleanup_zlib(z) do
    try do
      :zlib.inflateEnd(z)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :zlib.close(z)
  end

  # ---------------------------------------------------------------------------
  # Object finalisation
  # ---------------------------------------------------------------------------

  defp finish_object(state, cur, content, zlib_consumed) do
    new_buf = binary_part(state.buffer, zlib_consumed, byte_size(state.buffer) - zlib_consumed)
    new_bs = state.buffer_start + zlib_consumed

    if cur.write_handle != nil do
      # Streaming write path (Phase 3+): content already in the store via
      # write_handle chunks; just finalise and get the SHA back.
      # Raw content is NOT cached here (blobs/tags are rarely delta bases).
      case ObjectStore.close_write(state.store, cur.write_handle) do
        {:ok, sha, new_store} ->
          type = Common.type_atom(cur.type_code)

          {:ok,
           %{
             state
             | store: new_store,
               buffer: new_buf,
               buffer_start: new_bs,
               objects_done: state.objects_done + 1,
               offset_to_sha: Map.put(state.offset_to_sha, cur.obj_offset, {type, sha, 0}),
               sha_to_depth: Map.put(state.sha_to_depth, sha, 0),
               current: nil
           }}

        {:error, _} = err ->
          err
      end
    else
      # Traditional path: delta objects (content materialised from inflate_out)
      # and fallback for stores that returned {:error, :not_supported} from open_write.
      with {:ok, type, final_content, depth} <- resolve(state, cur, content),
           :ok <- check_depth(depth, state.limits.max_delta_depth),
           sha = Object.compute_sha(Atom.to_string(type), final_content),
           {:ok, obj} <- Object.decode(type, final_content),
           {:ok, _sha, new_store} <- ObjectStore.put(state.store, obj) do
        # Cache raw content for fast delta base resolution (avoids
        # zlib.uncompress + Object.decode + Object.encode round-trip).
        {new_raw_cache, new_raw_bytes} =
          maybe_cache_raw(state, sha, type, final_content)

        {:ok,
         %{
           state
           | store: new_store,
             buffer: new_buf,
             buffer_start: new_bs,
             objects_done: state.objects_done + 1,
             offset_to_sha: Map.put(state.offset_to_sha, cur.obj_offset, {type, sha, depth}),
             sha_to_depth: Map.put(state.sha_to_depth, sha, depth),
             raw_cache: new_raw_cache,
             raw_cache_bytes: new_raw_bytes,
             current: nil
         }}
      else
        {:error, _} = err -> err
        :error -> {:error, {:base_not_found, cur.obj_offset}}
      end
    end
  end

  defp check_depth(depth, max) when depth > max,
    do: {:error, {:delta_depth_exceeded, depth, max}}

  defp check_depth(_, _), do: :ok

  # ---------------------------------------------------------------------------
  # Delta resolution
  # ---------------------------------------------------------------------------

  # Regular objects: content is already the final bytes, depth = 0.
  defp resolve(_state, %{type_code: tc}, content) when tc in 1..4 do
    {:ok, Common.type_atom(tc), content, 0}
  end

  # OFS_DELTA: look up base via offset_to_sha, with raw_cache fast path.
  defp resolve(
         state,
         %{type_code: 6, ofs_base_offset: base_offset, obj_offset: obj_offset},
         delta
       ) do
    case Map.fetch(state.offset_to_sha, base_offset) do
      {:ok, {base_type, base_sha, base_depth}} ->
        case fetch_content(state, base_sha) do
          {:ok, base_content} ->
            case apply_delta(base_type, base_content, delta) do
              {:ok, type, result} -> {:ok, type, result, base_depth + 1}
              {:error, _} = err -> err
            end

          {:error, _} ->
            {:error, {:ofs_base_missing, base_sha}}
        end

      :error ->
        {:error, {:unresolved_ofs_delta, obj_offset, base_offset}}
    end
  end

  # REF_DELTA: fetch base directly by SHA, with raw_cache fast path.
  defp resolve(state, %{type_code: 7, ref_base_sha: base_sha}, delta) do
    base_depth = Map.get(state.sha_to_depth, base_sha, 0)

    case fetch_content_and_type(state, base_sha) do
      {:ok, base_content, base_type} ->
        case apply_delta(base_type, base_content, delta) do
          {:ok, type, result} -> {:ok, type, result, base_depth + 1}
          {:error, _} = err -> err
        end

      {:error, _} ->
        {:error, {:ref_delta_base_missing, base_sha}}
    end
  end

  defp apply_delta(base_type, base_content, delta) do
    case Delta.apply(base_content, delta) do
      {:ok, result} -> {:ok, base_type, result}
      {:error, _} = err -> err
    end
  end

  # Populate the raw-content cache if the budget allows.
  # Once the budget is exceeded we stop adding new entries (existing ones
  # remain valid until they're naturally evicted by SHA collision, which
  # doesn't happen since SHAs are unique).
  defp maybe_cache_raw(
         %{raw_cache: cache, raw_cache_bytes: used, limits: limits},
         sha,
         type,
         content
       ) do
    budget = limits.raw_cache_budget || 0
    content_size = byte_size(content)

    if budget > 0 and used + content_size <= budget do
      {Map.put(cache, sha, {type, content}), used + content_size}
    else
      {cache, used}
    end
  end

  defp fetch_content(state, sha) do
    case Map.fetch(state.raw_cache, sha) do
      {:ok, {_type, content}} -> {:ok, content}
      :error -> fetch_content_from_store(state.store, sha)
    end
  end

  defp fetch_content_from_store(store, sha) do
    case ObjectStore.get(store, sha) do
      {:ok, obj} -> {:ok, obj |> Object.encode() |> IO.iodata_to_binary()}
      {:error, _} = err -> err
    end
  end

  defp fetch_content_and_type(state, sha) do
    case Map.fetch(state.raw_cache, sha) do
      {:ok, {type, content}} -> {:ok, content, type}
      :error -> fetch_content_and_type_from_store(state.store, sha)
    end
  end

  defp fetch_content_and_type_from_store(store, sha) do
    case ObjectStore.get(store, sha) do
      {:ok, obj} ->
        {:ok, obj |> Object.encode() |> IO.iodata_to_binary(), Object.type(obj)}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Zlib boundary bisect helpers (shared with locate_boundary fallback)
  # ---------------------------------------------------------------------------

  defp bisect_complete(_data, lo, hi) when lo >= hi, do: lo

  defp bisect_complete(data, lo, hi) do
    mid = div(lo + hi, 2)

    if prefix_complete?(data, mid),
      do: bisect_complete(data, lo, mid),
      else: bisect_complete(data, mid + 1, hi)
  end

  # Does the first `n` bytes of `data` form a complete, well-terminated
  # zlib stream? Uses inflateEnd to detect the end-of-stream marker.
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
end
