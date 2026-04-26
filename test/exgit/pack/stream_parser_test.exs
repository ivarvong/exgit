defmodule Exgit.Pack.StreamParserTest do
  use ExUnit.Case, async: true

  alias Exgit.Object
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore.Memory
  alias Exgit.Pack.{Reader, StreamParser, Writer}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp new_store, do: Memory.new()

  # Feed `pack_binary` to a fresh StreamParser in one shot and finalise.
  defp parse_all(pack, store \\ nil) do
    store = store || new_store()
    parser = StreamParser.new(store)

    case StreamParser.ingest(parser, pack) do
      {:ok, parser} -> StreamParser.finalize(parser)
      {:error, _} = err -> err
    end
  end

  # Feed `pack_binary` byte-by-byte (maximum streaming pressure).
  defp parse_chunked(pack, chunk_size) do
    store = new_store()
    parser = StreamParser.new(store)

    result =
      pack
      |> :binary.bin_to_list()
      |> Enum.chunk_every(chunk_size)
      |> Enum.reduce_while({:ok, parser}, fn chunk, {:ok, p} ->
        case StreamParser.ingest(p, :erlang.list_to_binary(chunk)) do
          {:ok, p2} -> {:cont, {:ok, p2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, parser} -> StreamParser.finalize(parser)
      {:error, _} = err -> err
    end
  end

  # Collect all objects out of a store as {type, sha, content} triples.
  defp store_objects(store) do
    store.objects
    |> Enum.map(fn {sha, {type, compressed}} ->
      content = :zlib.uncompress(compressed)
      {type, sha, content}
    end)
    |> Enum.sort_by(fn {_, sha, _} -> sha end)
  end

  # ---------------------------------------------------------------------------
  # Basic correctness
  # ---------------------------------------------------------------------------

  describe "parse/1 correctness (parity with Pack.Reader)" do
    test "single blob" do
      blob = Blob.new("hello world\n")
      pack = Writer.build([blob])

      assert {:ok, 1, store} = parse_all(pack)
      objs = store_objects(store)
      assert [{:blob, _sha, "hello world\n"}] = objs
    end

    test "multiple blobs" do
      blobs = for i <- 1..5, do: Blob.new("blob #{i}\n")
      pack = Writer.build(blobs)

      assert {:ok, 5, store} = parse_all(pack)
      objs = store_objects(store)
      assert length(objs) == 5
      assert Enum.all?(objs, fn {t, _, _} -> t == :blob end)
    end

    test "empty pack (0 objects)" do
      # A valid pack with 0 objects is legal (e.g. when the server has
      # nothing new to send).
      pack = Writer.build([])
      assert {:ok, 0, _store} = parse_all(pack)
    end

    test "blob + tree + commit" do
      blob = Blob.new("readme content\n")
      blob_sha = Object.sha(blob)

      tree = Tree.new([{"100644", "README", blob_sha}])
      tree_sha = Object.sha(tree)

      commit =
        Commit.new(
          tree: tree_sha,
          author: "Test <t@t.com>",
          committer: "Test <t@t.com>",
          message: "init\n",
          parents: []
        )

      pack = Writer.build([blob, tree, commit])

      assert {:ok, 3, store} = parse_all(pack)
      objs = store_objects(store)
      assert length(objs) == 3
      types = Enum.map(objs, fn {t, _, _} -> t end) |> MapSet.new()
      assert MapSet.equal?(types, MapSet.new([:blob, :tree, :commit]))
    end

    test "produces same SHAs as Pack.Reader" do
      blobs = for i <- 1..8, do: Blob.new("data #{i} #{String.duplicate("x", 20)}\n")
      pack = Writer.build(blobs)

      {:ok, reader_objects} = Reader.parse(pack)
      {:ok, _n, store} = parse_all(pack)

      reader_shas = reader_objects |> Enum.map(fn {_, sha, _} -> sha end) |> MapSet.new()
      stream_shas = store_objects(store) |> Enum.map(fn {_, sha, _} -> sha end) |> MapSet.new()

      assert MapSet.equal?(reader_shas, stream_shas),
             "SHA mismatch between Reader and StreamParser"
    end
  end

  # ---------------------------------------------------------------------------
  # Chunked / streaming ingest
  # ---------------------------------------------------------------------------

  describe "chunked ingest" do
    test "byte-at-a-time ingest yields the same result as one-shot" do
      blobs = for i <- 1..4, do: Blob.new("chunked #{i}\n")
      pack = Writer.build(blobs)

      assert {:ok, 4, store_one} = parse_all(pack)
      assert {:ok, 4, store_chunk} = parse_chunked(pack, 1)

      shas_one = store_objects(store_one) |> Enum.map(fn {_, s, _} -> s end) |> MapSet.new()
      shas_chunk = store_objects(store_chunk) |> Enum.map(fn {_, s, _} -> s end) |> MapSet.new()

      assert MapSet.equal?(shas_one, shas_chunk)
    end

    test "4-byte chunk ingest" do
      blobs = for i <- 1..6, do: Blob.new("four #{i}")
      pack = Writer.build(blobs)

      assert {:ok, 6, _store} = parse_chunked(pack, 4)
    end

    test "object boundary crossing: chunk cuts across object header" do
      # Blob whose header varint is almost certainly split by a 3-byte chunk.
      blob = Blob.new(String.duplicate("a", 500))
      pack = Writer.build([blob])

      assert {:ok, 1, store} = parse_chunked(pack, 3)
      [{:blob, _sha, content}] = store_objects(store)
      assert byte_size(content) == 500
    end
  end

  # ---------------------------------------------------------------------------
  # Delta resolution (OFS_DELTA and REF_DELTA from real git)
  # ---------------------------------------------------------------------------

  describe "delta resolution" do
    @tag :git_cross_check
    @tag timeout: 30_000
    test "resolves OFS_DELTA objects from a git-repacked packfile" do
      tmp = Path.join(System.tmp_dir!(), "exgit_sp_delta_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      System.cmd("git", ["init", tmp], stderr_to_stdout: true)
      System.cmd("git", ["-C", tmp, "config", "user.email", "t@t.com"])
      System.cmd("git", ["-C", tmp, "config", "user.name", "Test"])

      for i <- 1..6 do
        content = Enum.map_join(1..25, "\n", fn l -> "line #{l} v#{i}" end) <> "\n"
        File.write!(Path.join(tmp, "file.txt"), content)
        System.cmd("git", ["-C", tmp, "add", "file.txt"])
        System.cmd("git", ["-C", tmp, "commit", "-m", "c#{i}"])
      end

      System.cmd("git", ["-C", tmp, "repack", "-a", "-d", "--window=10", "--depth=50"],
        stderr_to_stdout: true
      )

      pack_dir = Path.join([tmp, ".git", "objects", "pack"])
      {:ok, files} = File.ls(pack_dir)
      pack_file = Enum.find(files, &String.ends_with?(&1, ".pack"))

      if pack_file do
        pack_data = File.read!(Path.join(pack_dir, pack_file))

        # Both parsers must succeed and agree on SHA set.
        assert {:ok, reader_objects} = Reader.parse(pack_data)
        assert {:ok, _n, store} = parse_all(pack_data)

        reader_shas =
          reader_objects |> Enum.map(fn {_, sha, _} -> sha end) |> MapSet.new()

        stream_shas =
          store_objects(store) |> Enum.map(fn {_, sha, _} -> sha end) |> MapSet.new()

        assert MapSet.equal?(reader_shas, stream_shas),
               "Delta resolution produced different SHAs"
      else
        IO.puts("No packfile generated — skipping (no git binary or too few objects)")
      end

      File.rm_rf!(tmp)
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "rejects truncated pack (no header)" do
      assert {:error, :incomplete_pack_header} = parse_all(<<"PAC">>)
    end

    test "rejects invalid PACK signature" do
      bad = <<"JUNK", 0::32, 0::32, 0::160>>
      assert {:error, :invalid_pack_header} = parse_all(bad)
    end

    test "rejects unsupported pack version" do
      bad = <<"PACK", 1::32, 0::32, 0::160>>
      assert {:error, {:unsupported_pack_version, 1}} = parse_all(bad)
    end

    test "rejects corrupted checksum" do
      pack = Writer.build([Blob.new("x")])
      corrupted = binary_part(pack, 0, byte_size(pack) - 1) <> <<0xFF>>
      assert {:error, :checksum_mismatch} = parse_all(corrupted)
    end

    test "rejects object exceeding max_object_bytes" do
      blob = Blob.new(String.duplicate("z", 200))
      pack = Writer.build([blob])
      store = new_store()
      parser = StreamParser.new(store, max_object_bytes: 10)

      # Ingest might buffer everything before failing, or fail during inflate.
      result =
        case StreamParser.ingest(parser, pack) do
          {:ok, p} -> StreamParser.finalize(p)
          {:error, _} = err -> err
        end

      assert {:error, {:object_too_large, _, 10}} = result
    end

    test "rejects pack with too many objects" do
      blobs = for i <- 1..3, do: Blob.new("b#{i}")
      pack = Writer.build(blobs)
      store = new_store()
      parser = StreamParser.new(store, max_objects: 2)

      result =
        case StreamParser.ingest(parser, pack) do
          {:ok, p} -> StreamParser.finalize(p)
          {:error, _} = err -> err
        end

      assert {:error, {:too_many_objects, 3, 2}} = result
    end

    test "finalize on a fresh parser reports incomplete_pack_header" do
      parser = StreamParser.new(new_store())
      assert {:error, :incomplete_pack_header} = StreamParser.finalize(parser)
    end

    test "finalize after partial ingest reports incomplete_objects" do
      # Feed only the header (12 bytes) of a 1-object pack.
      blob = Blob.new("incomplete")
      pack = Writer.build([blob])
      header = binary_part(pack, 0, 12)

      parser = StreamParser.new(new_store())
      {:ok, parser} = StreamParser.ingest(parser, header)
      assert {:error, {:incomplete_objects, 1}} = StreamParser.finalize(parser)
    end
  end

  # ---------------------------------------------------------------------------
  # Memory bound
  # ---------------------------------------------------------------------------

  @tag :memory
  test "process heap stays bounded relative to pack size" do
    # 100 blobs × 16 KB = ~1.6 MB of raw content. The Memory store holds
    # all blobs compressed, plus the offset_to_sha map and parse state.
    # Peak heap should not exceed 8× the raw pack size — in practice it's
    # ~2-3× because the store compresses each blob.
    #
    # The key regression guard: we must NOT hold the entire pack binary
    # AND the full resolved-object list simultaneously (which was the old
    # Pack.Reader behaviour that OOM'd on esp-idf).
    blobs = for i <- 1..100, do: Blob.new(:binary.copy(<<rem(i, 251)>>, 16_384))
    pack = Writer.build(blobs)
    pack_size = byte_size(pack)

    :erlang.garbage_collect(self())
    {:memory, before_bytes} = :erlang.process_info(self(), :memory)

    assert {:ok, 100, _store} = parse_all(pack)

    :erlang.garbage_collect(self())
    {:memory, after_bytes} = :erlang.process_info(self(), :memory)

    growth = after_bytes - before_bytes

    # 8× headroom: store holds compressed blobs (~0.5× pack), offset_to_sha,
    # and BEAM allocator slack. We're asserting against worst-case growth,
    # not that we're hyper-efficient — Phase 3 will tighten this further.
    assert growth < 8 * pack_size,
           "Process memory grew by #{div(growth, 1024)} KB for a #{div(pack_size, 1024)} KB pack"
  end
end
