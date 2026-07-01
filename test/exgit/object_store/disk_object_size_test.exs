defmodule Exgit.ObjectStore.DiskObjectSizeTest do
  @moduledoc """
  Edge cases for `Disk.object_size/2`'s bounded header streaming:
  truncated zlib streams, non-zlib bytes, headers that exceed the
  scan budget, and the packed-object fallback. The happy loose path
  is covered in `Exgit.FsSizeTest`.
  """

  use ExUnit.Case, async: false

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore
  alias Exgit.Pack.Index
  alias Exgit.Test.PackBuilder

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "exgit_disk_size_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "objects"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: ObjectStore.Disk.new(root)}
  end

  describe "loose-object error paths" do
    test "truncated loose object (valid zlib prefix cut mid-stream) returns a clean error",
         %{root: root, store: store} do
      sha = :crypto.strong_rand_bytes(20)
      compressed = :zlib.compress("blob 5\0hello")
      # Keep only the 2-byte zlib stream header: a valid prefix that
      # inflates to nothing, so the NUL hunt runs out of input at EOF.
      write_loose(root, sha, binary_part(compressed, 0, 2))

      assert ObjectStore.object_size(store, sha) == {:error, :malformed_object_header}
    end

    test "corrupt non-zlib bytes return a clean error", %{root: root, store: store} do
      sha = :crypto.strong_rand_bytes(20)
      write_loose(root, sha, "definitely not a zlib stream")

      assert ObjectStore.object_size(store, sha) == {:error, :zlib_error}
    end

    test "header longer than the scan budget returns a clean error",
         %{root: root, store: store} do
      sha = :crypto.strong_rand_bytes(20)
      # Valid zlib, but the "header" never terminates: 200 bytes with
      # no NUL blows the @max_header_bytes budget instead of inflating
      # the whole object hunting for one.
      write_loose(root, sha, :zlib.compress("blob " <> String.duplicate("9", 200)))

      assert ObjectStore.object_size(store, sha) == {:error, :malformed_object_header}
    end
  end

  describe "packed-object fallback" do
    test "reports the exact content byte size for a packed blob",
         %{root: root, store: store} do
      content = "packed blob body " <> :crypto.strong_rand_bytes(1_000)
      sha = Blob.sha(Blob.new(content))

      pack = PackBuilder.build([{:full, :blob, content}])
      # Single-entry pack: the object spans from the 12-byte header to
      # the 20-byte checksum trailer.
      entry_bytes = binary_part(pack, 12, byte_size(pack) - 32)
      checksum = binary_part(pack, byte_size(pack) - 20, 20)
      idx = Index.write([{sha, :erlang.crc32(entry_bytes), 12}], checksum)

      pack_dir = Path.join(root, "objects/pack")
      File.mkdir_p!(pack_dir)
      File.write!(Path.join(pack_dir, "pack-size.pack"), pack)
      File.write!(Path.join(pack_dir, "pack-size.idx"), idx)

      # No loose object on disk, so this exercises the pack fallback.
      assert ObjectStore.object_size(store, sha) == {:ok, byte_size(content)}
    end
  end

  # Place raw bytes at the loose path for `sha`. object_size/2 only
  # parses the header — it never verifies the sha — so a random
  # 20-byte sha addresses whatever bytes we plant.
  defp write_loose(root, sha, bytes) do
    hex = Base.encode16(sha, case: :lower)
    <<prefix::binary-size(2), rest::binary>> = hex
    dir = Path.join([root, "objects", prefix])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, rest), bytes)
  end
end
