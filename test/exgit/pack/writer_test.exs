defmodule Exgit.Pack.WriterTest do
  use ExUnit.Case, async: true

  alias Exgit.Pack.{Writer, Reader}
  alias Exgit.Object.{Blob, Tree, Commit}

  describe "build/1" do
    test "produces a valid packfile header" do
      blob = Blob.new("test\n")
      pack = Writer.build([blob])

      <<"PACK", version::32-big, count::32-big, _rest::binary>> = pack
      assert version == 2
      assert count == 1
    end

    test "packfile has valid checksum" do
      blob = Blob.new("hello\n")
      pack = Writer.build([blob])

      pack_body = binary_part(pack, 0, byte_size(pack) - 20)
      checksum = binary_part(pack, byte_size(pack) - 20, 20)
      assert :crypto.hash(:sha, pack_body) == checksum
    end

    test "round-trips through reader for a single blob" do
      blob = Blob.new("round trip\n")
      pack = Writer.build([blob])

      assert {:ok, [{:blob, sha, content}]} = Reader.parse(pack)
      assert content == "round trip\n"
      assert sha == Blob.sha(blob)
    end

    test "round-trips multiple object types" do
      blob = Blob.new("file content\n")
      blob_sha = Blob.sha(blob)

      tree = Tree.new([{"100644", "file.txt", blob_sha}])
      tree_sha = Tree.sha(tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "A <a@b.com> 1000000000 +0000",
          committer: "A <a@b.com> 1000000000 +0000",
          message: "test\n"
        )

      commit_sha = Commit.sha(commit)

      pack = Writer.build([blob, tree, commit])
      assert {:ok, objects} = Reader.parse(pack)
      assert length(objects) == 3

      types = Enum.map(objects, &elem(&1, 0))
      assert :blob in types
      assert :tree in types
      assert :commit in types

      shas = Enum.map(objects, &elem(&1, 1))
      assert blob_sha in shas
      assert tree_sha in shas
      assert commit_sha in shas
    end

    @tag :git_cross_check
    test "packfile is accepted by git index-pack" do
      blob = Blob.new("git verify me\n")

      tree = Tree.new([{"100644", "test.txt", Blob.sha(blob)}])

      commit =
        Commit.new(
          tree: Tree.sha(tree),
          parents: [],
          author: "Test <t@t.com> 1000000000 +0000",
          committer: "Test <t@t.com> 1000000000 +0000",
          message: "verify\n"
        )

      pack = Writer.build([blob, tree, commit])

      tmp = Path.join(System.tmp_dir!(), "exgit_pack_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      pack_path = Path.join(tmp, "test.pack")
      File.write!(pack_path, pack)

      {output, status} =
        System.cmd("git", ["index-pack", pack_path], cd: tmp, stderr_to_stdout: true)

      assert status == 0, "git index-pack failed: #{output}"

      # git index-pack should have created a .idx file
      assert File.exists?(Path.join(tmp, "test.idx"))
      File.rm_rf!(tmp)
    end
  end
end
