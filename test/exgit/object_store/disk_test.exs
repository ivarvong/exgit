defmodule Exgit.ObjectStore.DiskTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore.Disk

  setup do
    path = Path.join(System.tmp_dir!(), "exgit_disk_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, "objects"))
    on_exit(fn -> File.rm_rf!(path) end)
    %{store: Disk.new(path), path: path}
  end

  describe "put and get" do
    test "round-trips a blob", %{store: store} do
      blob = Blob.new("hello disk\n")
      {:ok, sha} = Disk.put_object(store, blob)

      assert {:ok, retrieved} = Disk.get_object(store, sha)
      assert retrieved.data == "hello disk\n"
    end

    test "round-trips a tree", %{store: store} do
      blob = Blob.new("content\n")
      {:ok, blob_sha} = Disk.put_object(store, blob)

      tree = Tree.new([{"100644", "file.txt", blob_sha}])
      {:ok, tree_sha} = Disk.put_object(store, tree)

      assert {:ok, retrieved} = Disk.get_object(store, tree_sha)
      assert [{_mode, "file.txt", ^blob_sha}] = retrieved.entries
    end

    test "round-trips a commit", %{store: store} do
      tree_sha = :crypto.hash(:sha, "faketree")

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "A <a@b.com> 1000000000 +0000",
          committer: "A <a@b.com> 1000000000 +0000",
          message: "test\n"
        )

      {:ok, sha} = Disk.put_object(store, commit)
      assert {:ok, retrieved} = Disk.get_object(store, sha)
      assert retrieved.message == "test\n"
      assert Exgit.Object.Commit.tree(retrieved) == tree_sha
    end

    test "put is idempotent", %{store: store} do
      blob = Blob.new("idempotent")
      {:ok, sha1} = Disk.put_object(store, blob)
      {:ok, sha2} = Disk.put_object(store, blob)
      assert sha1 == sha2
    end
  end

  describe "has?" do
    test "returns true for existing objects", %{store: store} do
      blob = Blob.new("exists")
      {:ok, sha} = Disk.put_object(store, blob)

      assert Disk.has_object?(store, sha)
    end

    test "returns false for missing objects", %{store: store} do
      refute Disk.has_object?(store, :crypto.hash(:sha, "nope"))
    end
  end

  describe "object_size" do
    test "reads the size from the loose header without materializing", %{store: store} do
      data = String.duplicate("z", 300_000)
      {:ok, sha} = Disk.put_object(store, Blob.new(data))

      assert Disk.object_size(store, sha) == {:ok, byte_size(data)}
    end

    test "returns not_found for a missing object", %{store: store} do
      assert {:error, :not_found} = Disk.object_size(store, :crypto.hash(:sha, "absent"))
    end

    test "returns zlib_error for a corrupt loose object", %{store: store, path: path} do
      sha = :crypto.hash(:sha, "corrupt")
      write_loose_bytes(path, sha, "definitely not zlib data")

      assert {:error, :zlib_error} = Disk.object_size(store, sha)
    end

    test "returns malformed_object_header for a truncated loose object", %{
      store: store,
      path: path
    } do
      # Valid deflate stream cut off before the header's NUL appears.
      sha = :crypto.hash(:sha, "truncated")
      compressed = :zlib.compress("blob 1234\0" <> String.duplicate("y", 1234))
      write_loose_bytes(path, sha, binary_part(compressed, 0, 2))

      assert {:error, :malformed_object_header} = Disk.object_size(store, sha)
    end

    test "rejects a header with no NUL inside the scan budget", %{store: store, path: path} do
      sha = :crypto.hash(:sha, "no-nul")
      write_loose_bytes(path, sha, :zlib.compress(String.duplicate("a", 4096)))

      assert {:error, :malformed_object_header} = Disk.object_size(store, sha)
    end
  end

  defp write_loose_bytes(path, sha, bytes) do
    hex = Base.encode16(sha, case: :lower)
    <<prefix::binary-size(2), rest::binary>> = hex
    dir = Path.join([path, "objects", prefix])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, rest), bytes)
  end

  describe "delete" do
    test "removes the object", %{store: store} do
      blob = Blob.new("to delete")
      {:ok, sha} = Disk.put_object(store, blob)

      assert :ok = Disk.delete_object(store, sha)
      refute Disk.has_object?(store, sha)
    end

    test "returns error for missing object", %{store: store} do
      assert {:error, :not_found} = Disk.delete_object(store, :crypto.hash(:sha, "missing"))
    end
  end

  describe "list" do
    test "lists all stored objects", %{store: store} do
      {:ok, sha1} = Disk.put_object(store, Blob.new("a"))
      {:ok, sha2} = Disk.put_object(store, Blob.new("b"))

      shas = Disk.list_objects(store)
      assert sha1 in shas
      assert sha2 in shas
    end
  end

  describe "git compatibility" do
    @tag :git_cross_check
    test "objects are readable by git cat-file", %{store: store, path: path} do
      File.mkdir_p!(Path.join(path, "refs"))
      File.write!(Path.join(path, "HEAD"), "ref: refs/heads/main\n")

      blob = Blob.new("hello from exgit\n")
      {:ok, sha} = Disk.put_object(store, blob)
      hex = Base.encode16(sha, case: :lower)

      {output, 0} = System.cmd("git", ["cat-file", "-p", hex], cd: path)
      assert output == "hello from exgit\n"

      {type, 0} = System.cmd("git", ["cat-file", "-t", hex], cd: path)
      assert String.trim(type) == "blob"
    end
  end
end
