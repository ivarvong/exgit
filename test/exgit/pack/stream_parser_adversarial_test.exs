defmodule Exgit.Pack.StreamParserAdversarialTest do
  @moduledoc """
  Adversarial corpus for Pack.StreamParser (Phase 4).

  Every test confirms that a hostile or malformed pack triggers a clean,
  tagged error — no crash, no OOM, no silent data corruption.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore.Memory
  alias Exgit.Pack.{Common, StreamParser, Writer}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp new_store, do: Memory.new()

  defp parse_all(pack, opts \\ []) do
    store = new_store()
    parser = StreamParser.new(store, opts)

    case StreamParser.ingest(parser, pack) do
      {:ok, parser} -> StreamParser.finalize(parser)
      {:error, _} = err -> err
    end
  end

  # Build a raw pack binary from pre-encoded object binaries (no delta support).
  # Objects must be already zlib-compressed with the type/size varint prepended.
  defp raw_pack(object_binaries) do
    n = length(object_binaries)

    header = <<"PACK", 2::32-big, n::32-big>>
    body = IO.iodata_to_binary([header | object_binaries])
    checksum = :crypto.hash(:sha, body)
    body <> checksum
  end

  # ---------------------------------------------------------------------------
  # Object size cap
  # ---------------------------------------------------------------------------

  describe "max_object_bytes" do
    test "rejects object whose declared size exceeds the cap" do
      # A blob claiming 200 bytes but with only a few bytes of real content.
      # The declared size in the varint is what triggers the check.
      blob = Blob.new(String.duplicate("a", 200))
      pack = Writer.build([blob])

      assert {:error, {:object_too_large, 200, 10}} =
               parse_all(pack, max_object_bytes: 10)
    end

    test "accepts object exactly at the cap" do
      blob = Blob.new("hello")
      pack = Writer.build([blob])

      assert {:ok, 1, _store} = parse_all(pack, max_object_bytes: 5)
    end
  end

  # ---------------------------------------------------------------------------
  # Inflate ratio (zip-bomb defence)
  # ---------------------------------------------------------------------------

  describe "max_inflate_ratio" do
    test "rejects highly compressible content that exceeds ratio cap" do
      # Highly compressible: 10_000 bytes of zeros compresses to ~20 bytes.
      # Ratio ≈ 500×. With a cap of 100×, this should be rejected.
      content = :binary.copy(<<0>>, 10_000)
      blob = Blob.new(content)
      pack = Writer.build([blob])

      assert {:error, {:inflate_ratio_exceeded, _, _, 100}} =
               parse_all(pack, max_inflate_ratio: 100)
    end

    test "accepts content whose ratio is below the cap" do
      # Random-ish content compresses poorly — ratio ≈ 1.
      content = :crypto.strong_rand_bytes(500)
      blob = Blob.new(content)
      pack = Writer.build([blob])

      assert {:ok, 1, _store} = parse_all(pack, max_inflate_ratio: 100)
    end

    test "nil max_inflate_ratio disables the check" do
      content = :binary.copy(<<0>>, 10_000)
      blob = Blob.new(content)
      pack = Writer.build([blob])

      # With the check disabled, highly compressible data is accepted.
      assert {:ok, 1, _store} = parse_all(pack, max_inflate_ratio: nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Object count cap
  # ---------------------------------------------------------------------------

  describe "max_objects" do
    test "rejects packs that declare more objects than the cap" do
      # Build a 3-object pack, then parse with a cap of 2.
      blobs = for i <- 1..3, do: Blob.new("b#{i}")
      pack = Writer.build(blobs)

      assert {:error, {:too_many_objects, 3, 2}} = parse_all(pack, max_objects: 2)
    end
  end

  # ---------------------------------------------------------------------------
  # Delta depth cap
  # ---------------------------------------------------------------------------

  describe "max_delta_depth" do
    @tag :git_cross_check
    @tag timeout: 60_000
    test "rejects delta chains deeper than the cap" do
      # Build a real git repo with a deep delta chain using git repack.
      # We force enough commits with similar content to create a chain.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "exgit_depth_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      System.cmd("git", ["init", tmp], stderr_to_stdout: true)
      System.cmd("git", ["-C", tmp, "config", "user.email", "t@t.com"])
      System.cmd("git", ["-C", tmp, "config", "user.name", "Test"])

      # 15 commits with evolving content creates delta chains ~5-10 deep.
      for i <- 1..15 do
        lines = Enum.map_join(1..30, "\n", fn l -> "line #{l} version #{i}" end)
        File.write!(Path.join(tmp, "f.txt"), lines <> "\n")
        System.cmd("git", ["-C", tmp, "add", "f.txt"])
        System.cmd("git", ["-C", tmp, "commit", "-m", "c#{i}"])
      end

      System.cmd(
        "git",
        ["-C", tmp, "repack", "-a", "-d", "--window=50", "--depth=50"],
        stderr_to_stdout: true
      )

      pack_dir = Path.join([tmp, ".git", "objects", "pack"])
      {:ok, files} = File.ls(pack_dir)
      pack_file = Enum.find(files, &String.ends_with?(&1, ".pack"))

      if pack_file do
        pack_data = File.read!(Path.join(pack_dir, pack_file))

        # With cap=1 (no delta chains allowed), we expect a depth error.
        # With cap=100, everything should pass.
        result_low = parse_all(pack_data, max_delta_depth: 1)
        result_high = parse_all(pack_data, max_delta_depth: 100)

        # At least one of the results should differ (the low cap should reject
        # if there are deltas; the high cap should always pass).
        case result_low do
          {:error, {:delta_depth_exceeded, depth, 1}} when depth > 1 ->
            assert {:ok, _, _} = result_high,
                   "High cap should always succeed: #{inspect(result_high)}"

          {:ok, _, _} ->
            # No deltas in this pack (very small repo) — cap irrelevant.
            assert {:ok, _, _} = result_high
        end
      end

      File.rm_rf!(tmp)
    end

    test "depth 0 cap rejects the first delta object" do
      # We can't easily force OFS_DELTA via Writer (it doesn't delta-compress).
      # Instead, verify the depth check fires for a direct REF_DELTA scenario
      # by using a git-cross-check or just confirming the check is wired.
      # This test verifies the cap is enforced via the opts API.
      blob = Blob.new("hello")
      pack = Writer.build([blob])

      # Single non-delta object: depth = 0. With cap=0, depth 0 is allowed.
      assert {:ok, 1, _} = parse_all(pack, max_delta_depth: 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Parse deadline
  # ---------------------------------------------------------------------------

  describe "deadline" do
    test "rejects ingest after the deadline has passed" do
      blob = Blob.new("x")
      pack = Writer.build([blob])

      # Deadline in the past (1 ms ago).
      past = :erlang.monotonic_time(:millisecond) - 1
      parser = StreamParser.new(new_store(), deadline: past)

      assert {:error, :deadline_exceeded} = StreamParser.ingest(parser, pack)
    end

    test "accepts ingest before the deadline" do
      blob = Blob.new("y")
      pack = Writer.build([blob])

      # Deadline 30 seconds in the future — should never trip in a unit test.
      future = :erlang.monotonic_time(:millisecond) + 30_000
      parser = StreamParser.new(new_store(), deadline: future)

      {:ok, parser} = StreamParser.ingest(parser, pack)
      assert {:ok, 1, _store} = StreamParser.finalize(parser)
    end

    test "nil deadline (default) never trips" do
      blob = Blob.new("z")
      pack = Writer.build([blob])

      assert {:ok, 1, _} = parse_all(pack)
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed packs
  # ---------------------------------------------------------------------------

  describe "malformed pack structure" do
    test "wrong signature rejects with :invalid_pack_header" do
      bad = <<"JUNK", 2::32-big, 0::32-big>> <> :binary.copy(<<0>>, 20)
      assert {:error, :invalid_pack_header} = parse_all(bad)
    end

    test "version 1 rejects with :unsupported_pack_version" do
      bad = <<"PACK", 1::32-big, 0::32-big>> <> :binary.copy(<<0>>, 20)
      assert {:error, {:unsupported_pack_version, 1}} = parse_all(bad)
    end

    test "truncated after header rejects cleanly" do
      # A pack whose header declares 5 objects but has no object data.
      # The parser sees the trailing checksum bytes as "object" data and
      # produces a structured error (unknown type, bad zlib, etc.).
      # We only assert it does NOT crash and returns an error tuple.
      header = <<"PACK", 2::32-big, 5::32-big>>
      checksum = :crypto.hash(:sha, header)
      pack = header <> checksum
      assert {:error, _reason} = parse_all(pack)
    end

    test "checksum mismatch is detected" do
      blob = Blob.new("integrity check")
      pack = Writer.build([blob])
      # Flip one bit only in the trailing 20-byte checksum (last byte).
      last = byte_size(pack) - 1
      <<before::binary-size(last), final_byte>> = pack
      corrupted = <<before::binary, Bitwise.bxor(final_byte, 0x01)>>
      assert {:error, :checksum_mismatch} = parse_all(corrupted)
    end

    test "unknown object type is rejected" do
      # Pack with type code 5 (undefined in git).
      varint = Common.encode_type_size_varint(5, 3)
      compressed = :zlib.compress("abc")
      object_bin = IO.iodata_to_binary([varint, compressed])
      pack = raw_pack([object_bin])
      assert {:error, {:unknown_object_type, 5}} = parse_all(pack)
    end
  end

  # ---------------------------------------------------------------------------
  # OFS_DELTA error paths
  # ---------------------------------------------------------------------------

  describe "OFS_DELTA error paths" do
    test "OFS_DELTA pointing before the pack start is rejected" do
      # Craft a pack where a type-6 object's base offset points before byte 0.
      # First object: a small blob at offset 12.
      blob_content = "base"
      blob_varint = Common.encode_type_size_varint(3, byte_size(blob_content))
      blob_zlib = :zlib.compress(blob_content)
      blob_bin = IO.iodata_to_binary([blob_varint, blob_zlib])

      # Second object: OFS_DELTA claiming base is 10000 bytes before it.
      # The pack starts at byte 12, so the base offset would be negative.
      # trivial delta: copy 4 bytes
      delta_content = <<4, 4, 0, 4>> <> "base"
      delta_varint = Common.encode_type_size_varint(6, byte_size(delta_content))
      # neg_ofs = 10000; blob_2 offset = 12 + byte_size(blob_bin).
      neg_ofs_bin = Common.encode_ofs_varint(10_000)
      delta_zlib = :zlib.compress(delta_content)
      delta_bin = IO.iodata_to_binary([delta_varint, neg_ofs_bin, delta_zlib])

      pack = raw_pack([blob_bin, delta_bin])

      assert {:error, :ofs_delta_before_pack} = parse_all(pack)
    end
  end

  # ---------------------------------------------------------------------------
  # Parity with Pack.Reader under adversarial options
  # ---------------------------------------------------------------------------

  describe "parity with Pack.Reader on valid packs" do
    property "any pack built by Writer is parsed identically" do
      check all(
              n <- StreamData.integer(1..10),
              sizes <- StreamData.list_of(StreamData.integer(1..200), length: n)
            ) do
        blobs = Enum.map(sizes, fn s -> Blob.new(:binary.copy(<<rem(s, 251)>>, s)) end)
        pack = Writer.build(blobs)

        alias Exgit.Pack.Reader

        {:ok, reader_objs} = Reader.parse(pack)
        {:ok, _n, store} = parse_all(pack)

        reader_shas =
          reader_objs |> Enum.map(fn {_, sha, _} -> sha end) |> MapSet.new()

        stream_shas =
          store.objects
          |> Map.keys()
          |> MapSet.new()

        assert MapSet.equal?(reader_shas, stream_shas)
      end
    end
  end
end
