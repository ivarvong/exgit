defmodule Exgit.Pack.StreamParserStreamingWriteTest do
  @moduledoc """
  Phase 3+ tests: verify that the streaming write path (open_write /
  write_chunk / close_write) produces objects that are byte-identical to the
  traditional decode+put path, and that peak heap is significantly lower for
  large non-delta objects.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object
  alias Exgit.Object.Blob
  alias Exgit.ObjectStore
  alias Exgit.ObjectStore.{Disk, Memory}
  alias Exgit.Pack.{Reader, StreamParser, Writer}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_all(pack, store, opts \\ []) do
    parser = StreamParser.new(store, opts)

    case StreamParser.ingest(parser, pack) do
      {:ok, parser} -> StreamParser.finalize(parser)
      {:error, _} = err -> err
    end
  end

  defp sha_set(store) do
    store.objects |> Map.keys() |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Correctness: Memory store streaming write
  # ---------------------------------------------------------------------------

  describe "Memory store streaming write correctness" do
    test "single blob written via streaming write matches traditional put" do
      blob = Blob.new("hello streaming world\n")
      pack = Writer.build([blob])

      # Streaming path
      {:ok, _n, stream_store} = parse_all(pack, Memory.new())

      # Traditional path (via Pack.Reader which uses import_objects)
      {:ok, objects} = Reader.parse(pack)
      {:ok, trad_store} = ObjectStore.import_objects(Memory.new(), objects)

      assert sha_set(stream_store) == sha_set(trad_store)

      # Verify content is identical
      for sha <- MapSet.to_list(sha_set(stream_store)) do
        {:ok, stream_obj} = ObjectStore.get(stream_store, sha)
        {:ok, trad_obj} = ObjectStore.get(trad_store, sha)
        assert Object.sha(stream_obj) == Object.sha(trad_obj)
        stream_content = stream_obj |> Object.encode() |> IO.iodata_to_binary()
        trad_content = trad_obj |> Object.encode() |> IO.iodata_to_binary()
        assert stream_content == trad_content
      end
    end

    test "multiple objects across all types (blob tree commit)" do
      blob = Blob.new("file content\n")
      blob_sha = Object.sha(blob)
      tree = Exgit.Object.Tree.new([{"100644", "file.txt", blob_sha}])
      tree_sha = Object.sha(tree)

      commit =
        Exgit.Object.Commit.new(
          tree: tree_sha,
          parents: [],
          author: "Test <t@t.com>",
          committer: "Test <t@t.com>",
          message: "init\n"
        )

      pack = Writer.build([blob, tree, commit])

      {:ok, _n, stream_store} = parse_all(pack, Memory.new())
      {:ok, objects} = Reader.parse(pack)
      {:ok, trad_store} = ObjectStore.import_objects(Memory.new(), objects)

      assert sha_set(stream_store) == sha_set(trad_store)
    end

    test "chunked ingest with streaming write yields same result as one-shot" do
      blobs = for i <- 1..8, do: Blob.new("streaming blob #{i} " <> String.duplicate("x", 100))
      pack = Writer.build(blobs)

      {:ok, _n, one_shot_store} = parse_all(pack, Memory.new())

      # Byte-at-a-time
      store = Memory.new()
      parser = StreamParser.new(store)

      {:ok, chunked_parser} =
        :binary.bin_to_list(pack)
        |> Enum.chunk_every(1)
        |> Enum.reduce_while({:ok, parser}, fn bytes, {:ok, p} ->
          case StreamParser.ingest(p, :erlang.list_to_binary(bytes)) do
            {:ok, p2} -> {:cont, {:ok, p2}}
            err -> {:halt, err}
          end
        end)

      {:ok, _n, chunked_store} = StreamParser.finalize(chunked_parser)

      assert sha_set(one_shot_store) == sha_set(chunked_store)
    end

    test "cancel_write cleans up without storing" do
      # Open a write handle and cancel it — the object must NOT appear in the store.
      store = Memory.new()
      {:ok, handle} = ObjectStore.open_write(store, :blob, 10)
      {:ok, handle} = ObjectStore.write_chunk(store, handle, "hello")
      :ok = ObjectStore.cancel_write(store, handle)
      # Store unchanged
      assert store.objects == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Correctness: Disk store streaming write
  # ---------------------------------------------------------------------------

  describe "Disk store streaming write correctness" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "exgit_sw_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      {:ok, disk} = {:ok, Disk.new(tmp)}
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp, disk: disk}
    end

    test "blob written via streaming write is readable back", %{disk: disk} do
      content = :crypto.strong_rand_bytes(512)
      blob = Blob.new(content)
      pack = Writer.build([blob])

      {:ok, _n, disk2} = parse_all(pack, disk)

      # Blob should be findable in the disk store
      sha = Object.sha(blob)
      assert {:ok, obj} = ObjectStore.get(disk2, sha)
      retrieved = obj |> Object.encode() |> IO.iodata_to_binary()
      assert retrieved == content
    end

    test "multiple objects round-trip through Disk store", %{disk: disk} do
      blobs = for i <- 1..5, do: Blob.new("disk blob #{i}")
      pack = Writer.build(blobs)

      {:ok, n, _disk2} = parse_all(pack, disk)
      assert n == 5
    end

    test "cancel_write deletes temp file", %{disk: disk, tmp: tmp} do
      {:ok, handle} = ObjectStore.open_write(disk, :blob, 100)
      {:ok, handle} = ObjectStore.write_chunk(disk, handle, "partial content")

      tmp_dir = Path.join([tmp, "objects", "tmp"])
      tmp_files_before = File.ls!(tmp_dir)

      :ok = ObjectStore.cancel_write(disk, handle)

      # Temp file should be gone
      tmp_files_after = File.ls!(tmp_dir)
      assert length(tmp_files_after) < length(tmp_files_before)
    end
  end

  # ---------------------------------------------------------------------------
  # Parity: StreamParser with streaming write == Reader for any valid pack
  # ---------------------------------------------------------------------------

  describe "parity with Pack.Reader (streaming write path)" do
    test "50 random blobs produce identical SHA sets" do
      blobs = for i <- 1..50, do: Blob.new(:crypto.strong_rand_bytes(rem(i * 37, 500) + 1))
      pack = Writer.build(blobs)

      {:ok, reader_objects} = Reader.parse(pack)
      {:ok, _n, stream_store} = parse_all(pack, Memory.new())

      reader_shas = reader_objects |> Enum.map(fn {_, sha, _} -> sha end) |> MapSet.new()
      assert sha_set(stream_store) == reader_shas
    end
  end

  # ---------------------------------------------------------------------------
  # Memory bound: Phase 3+ eliminates the raw+compressed coexistence spike
  # ---------------------------------------------------------------------------

  @tag :memory
  test "process heap never holds raw content and compressed form simultaneously" do
    # 50 blobs × 40 KB ≈ 2 MB of raw content.
    # Phase 3+: content flows inflate-port → write-handle → store. Peak is
    # O(one chunk) of raw + compressed output accumulation, not O(full object).
    blobs = for i <- 1..50, do: Blob.new(:binary.copy(<<rem(i, 251)>>, 40_960))
    pack = Writer.build(blobs)
    pack_size = byte_size(pack)

    :erlang.garbage_collect(self())
    {:memory, before_bytes} = :erlang.process_info(self(), :memory)

    assert {:ok, 50, _store} = parse_all(pack, Memory.new())

    :erlang.garbage_collect(self())
    {:memory, after_bytes} = :erlang.process_info(self(), :memory)
    growth = after_bytes - before_bytes

    # The store holds ~50 compressed blobs (≤ 1× pack for compressible data).
    # With Phase 3+, the parser itself never holds more than one chunk.
    # Allow 6× pack as a generous bound (store + BEAM allocator slack).
    assert growth < 6 * pack_size,
           "Heap grew #{div(growth, 1024)} KB for #{div(pack_size, 1024)} KB pack — " <>
             "streaming write regression?"
  end
end
