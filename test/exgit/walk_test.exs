defmodule Exgit.WalkTest do
  use ExUnit.Case, async: true

  alias Exgit.{Walk, Repository, ObjectStore.Memory}
  alias Exgit.Object.Commit

  defp make_repo, do: Repository.new(Memory.new(), Exgit.RefStore.Memory.new())

  defp put!(repo, object) do
    {:ok, sha, store} = Memory.put_object(repo.object_store, object)
    {sha, %{repo | object_store: store}}
  end

  defp make_commit(repo, opts) do
    tree_sha = Keyword.get(opts, :tree, :crypto.hash(:sha, "empty_tree"))
    parents = Keyword.get(opts, :parents, [])
    ts = Keyword.fetch!(opts, :timestamp)

    commit =
      Commit.new(
        tree: tree_sha,
        parents: parents,
        author: "Test <t@t.com> #{ts} +0000",
        committer: "Test <t@t.com> #{ts} +0000",
        message: Keyword.get(opts, :message, "commit\n")
      )

    put!(repo, commit)
  end

  describe "ancestors/3" do
    test "walks a linear chain" do
      repo = make_repo()

      {c1, repo} = make_commit(repo, timestamp: 1000)
      {c2, repo} = make_commit(repo, parents: [c1], timestamp: 2000)
      {c3, repo} = make_commit(repo, parents: [c2], timestamp: 3000)

      shas =
        repo
        |> Walk.ancestors(c3)
        |> Enum.map(&Commit.sha/1)

      assert shas == [c3, c2, c1]
    end

    test "walks with limit" do
      repo = make_repo()

      {c1, repo} = make_commit(repo, timestamp: 1000)
      {c2, repo} = make_commit(repo, parents: [c1], timestamp: 2000)
      {c3, repo} = make_commit(repo, parents: [c2], timestamp: 3000)

      shas =
        repo
        |> Walk.ancestors(c3, limit: 2)
        |> Enum.map(&Commit.sha/1)

      assert length(shas) == 2
      assert hd(shas) == c3
    end

    test "handles merge commits (diamond)" do
      repo = make_repo()

      {base, repo} = make_commit(repo, timestamp: 1000, message: "base\n")
      {left, repo} = make_commit(repo, parents: [base], timestamp: 2000, message: "left\n")
      {right, repo} = make_commit(repo, parents: [base], timestamp: 2001, message: "right\n")

      {merge, repo} =
        make_commit(repo, parents: [left, right], timestamp: 3000, message: "merge\n")

      shas =
        repo
        |> Walk.ancestors(merge)
        |> Enum.map(&Commit.sha/1)

      # All 4 commits visited, base only once
      assert length(shas) == 4
      assert hd(shas) == merge
      assert base in shas
      assert left in shas
      assert right in shas
    end

    test "handles root commit (no parents)" do
      repo = make_repo()
      {root, repo} = make_commit(repo, timestamp: 1000)

      shas =
        repo
        |> Walk.ancestors(root)
        |> Enum.map(&Commit.sha/1)

      assert shas == [root]
    end
  end

  describe "merge_base/2" do
    test "finds merge base of a diamond" do
      repo = make_repo()

      {base, repo} = make_commit(repo, timestamp: 1000)
      {left, repo} = make_commit(repo, parents: [base], timestamp: 2000)
      {right, repo} = make_commit(repo, parents: [base], timestamp: 2001)

      assert {:ok, ^base} = Walk.merge_base(repo, [left, right])
    end

    test "returns the commit itself when both are the same" do
      repo = make_repo()
      {c, repo} = make_commit(repo, timestamp: 1000)

      assert {:ok, ^c} = Walk.merge_base(repo, [c, c])
    end

    test "returns error when no common ancestor" do
      repo = make_repo()

      {a, repo} = make_commit(repo, timestamp: 1000, message: "a\n")
      {b, repo} = make_commit(repo, timestamp: 2000, message: "b\n")

      assert {:error, :none} = Walk.merge_base(repo, [a, b])
    end
  end
end
