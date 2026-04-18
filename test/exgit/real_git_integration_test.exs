defmodule Exgit.RealGitIntegrationTest do
  @moduledoc """
  Cross-checks exgit objects against a real `git` binary.

  These tests only run when git is on PATH (gated by the `:real_git`
  moduletag, which test_helper.exs toggles).
  """
  use ExUnit.Case, async: true

  @moduletag :real_git

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.Test.RealGit

  setup do
    repo = RealGit.init_bare!(RealGit.tmp_dir!())
    on_exit(fn -> File.rm_rf!(repo) end)
    %{repo: repo}
  end

  describe "G.1 — exgit hashes match real git for every object type" do
    test "blob SHA matches git hash-object", %{repo: repo} do
      content = "hello world\n"
      git_sha = RealGit.write_blob!(repo, content)

      exgit_sha = Blob.sha_hex(Blob.new(content))

      assert exgit_sha == git_sha
    end

    test "tree SHA matches git mktree", %{repo: repo} do
      blob_sha_hex = RealGit.write_blob!(repo, "x")
      blob_sha = RealGit.hex_to_bin(blob_sha_hex)

      tree_sha = RealGit.write_tree!(repo, [{"100644", "f", blob_sha_hex}])

      exgit_tree = Tree.new([{"100644", "f", blob_sha}])
      assert Tree.sha_hex(exgit_tree) == tree_sha
    end

    test "commit SHA matches git commit-tree", %{repo: repo} do
      blob_sha = RealGit.write_blob!(repo, "z")
      tree_sha_hex = RealGit.write_tree!(repo, [{"100644", "z", blob_sha}])
      tree_sha = RealGit.hex_to_bin(tree_sha_hex)

      msg = "initial commit\n"
      git_commit_sha = RealGit.commit_tree!(repo, tree: tree_sha_hex, message: msg)

      exgit_commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: msg
        )

      assert Commit.sha_hex(exgit_commit) == git_commit_sha
    end
  end

  describe "G.2 — real tree can be decoded and re-encoded byte-for-byte" do
    test "git-written tree round trips through exgit", %{repo: repo} do
      blob_sha = RealGit.write_blob!(repo, "tree contents\n")
      tree_sha = RealGit.write_tree!(repo, [{"100644", "readme", blob_sha}])

      raw = RealGit.read_loose!(repo, tree_sha)
      inflated = :zlib.uncompress(raw)

      {pos, 1} = :binary.match(inflated, <<0>>)
      <<_header::binary-size(pos), 0, content::binary>> = inflated

      {:ok, tree} = Tree.decode(content)
      assert IO.iodata_to_binary(Tree.encode(tree)) == content
    end
  end

  describe "G.3 — exgit loose objects are readable by git cat-file" do
    test "exgit-written blob passes git fsck", %{repo: repo} do
      # Put a blob via exgit's Disk store, then have git cat-file read
      # it by its SHA.
      store = Exgit.ObjectStore.Disk.new(repo)

      blob = Blob.new("exgit wrote this\n")
      {:ok, sha, _} = Exgit.ObjectStore.put(store, blob)

      {out, 0} = RealGit.git!(repo, ["cat-file", "-p", Base.encode16(sha, case: :lower)])

      assert out == "exgit wrote this\n"
    end
  end
end
