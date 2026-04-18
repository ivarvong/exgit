defmodule Exgit.Object.CommitTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit}
  import Exgit.Test.GitHelper

  @author "Test User <test@example.com> 1000000000 +0000"

  describe "encode/decode round-trip" do
    test "round-trips a root commit" do
      tree_sha = :crypto.hash(:sha, "tree")

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: @author,
          committer: @author,
          message: "initial commit\n"
        )

      encoded = commit |> Commit.encode() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Commit.decode(encoded)
      assert Commit.tree(decoded) == tree_sha
      assert Commit.parents(decoded) == []
      assert Commit.author(decoded) == @author
      assert Commit.committer(decoded) == @author
      assert decoded.message == "initial commit\n"
    end

    test "round-trips a commit with parents" do
      tree_sha = :crypto.hash(:sha, "tree")
      parent1 = :crypto.hash(:sha, "p1")
      parent2 = :crypto.hash(:sha, "p2")

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [parent1, parent2],
          author: @author,
          committer: @author,
          message: "merge\n"
        )

      encoded = commit |> Commit.encode() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Commit.decode(encoded)
      assert Commit.parents(decoded) == [parent1, parent2]
    end
  end

  describe "sha/1" do
    @tag :git_cross_check
    test "matches git commit-tree" do
      tmp = System.tmp_dir!()
      repo = Path.join(tmp, "exgit_commit_test_#{System.unique_integer([:positive])}")
      System.cmd("git", ["init", "--bare", repo])

      blob_data = "hello\n"
      {_, 0} = cmd_with_stdin("git", ["hash-object", "-w", "--stdin"], blob_data, cd: repo)
      blob = Blob.new(blob_data)

      tree_input = "100644 blob #{Blob.sha_hex(blob)}\thello.txt\n"
      {tree_hex, 0} = cmd_with_stdin("git", ["mktree"], tree_input, cd: repo)
      tree_hex = String.trim(tree_hex)
      tree_sha = Base.decode16!(tree_hex, case: :lower)

      author = "Test User <test@example.com> 1000000000 +0000"

      env = [
        {"GIT_AUTHOR_NAME", "Test User"},
        {"GIT_AUTHOR_EMAIL", "test@example.com"},
        {"GIT_AUTHOR_DATE", "1000000000 +0000"},
        {"GIT_COMMITTER_NAME", "Test User"},
        {"GIT_COMMITTER_EMAIL", "test@example.com"},
        {"GIT_COMMITTER_DATE", "1000000000 +0000"}
      ]

      msg = "initial commit\n"

      {git_sha, 0} =
        cmd_with_stdin("git", ["commit-tree", tree_hex, "-m", msg], "", cd: repo, env: env)

      git_sha = String.trim(git_sha)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: author,
          committer: author,
          message: msg
        )

      assert Commit.sha_hex(commit) == git_sha
      File.rm_rf!(repo)
    end
  end
end
