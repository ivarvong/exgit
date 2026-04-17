defmodule Exgit.ObjectStore.DiskIntegrityTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore

  setup do
    root = Path.join(System.tmp_dir!(), "exgit_disk_integ_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: ObjectStore.Disk.new(root)}
  end

  describe "integrity check on read (P3.2)" do
    test "corrupting an object on disk yields an error, not wrong data", %{
      root: root,
      store: store
    } do
      blob = Blob.new("the real content\n")
      {:ok, sha, _} = ObjectStore.put(store, blob)

      <<a::binary-size(2), rest::binary>> = Base.encode16(sha, case: :lower)
      path = Path.join([root, "objects", a, rest])

      # Corrupt: replace with zlib-compressed BUT different content.
      # We keep valid zlib so the decompression succeeds — but the bytes
      # differ, so the SHA must not match.
      fake = :zlib.compress("blob 13\0different fake")
      File.write!(path, fake)

      assert {:error, {:sha_mismatch, ^sha}} = ObjectStore.get(store, sha)
    end
  end
end
