defmodule Exgit.DiffTest do
  use ExUnit.Case, async: true

  alias Exgit.{Diff, ObjectStore.Memory, Repository}
  alias Exgit.Object.{Blob, Tree}

  defp make_repo, do: Repository.new(Memory.new(), Exgit.RefStore.Memory.new())

  defp put!(repo, object) do
    {:ok, sha, store} = Memory.put_object(repo.object_store, object)
    {sha, %{repo | object_store: store}}
  end

  defp make_tree(repo, files) do
    {entries, repo} =
      Enum.reduce(files, {[], repo}, fn
        {name, :tree, sub_files}, {entries, repo} ->
          {sub_sha, repo} = make_tree(repo, sub_files)
          {[{"40000", name, sub_sha} | entries], repo}

        {name, content}, {entries, repo} ->
          {sha, repo} = put!(repo, Blob.new(content))
          {[{"100644", name, sha} | entries], repo}
      end)

    tree = Tree.new(entries)
    put!(repo, tree)
  end

  describe "trees/4" do
    test "empty trees have no diff" do
      repo = make_repo()
      {sha_a, repo} = make_tree(repo, [])
      assert {:ok, []} = Diff.trees(repo, sha_a, sha_a)
    end

    test "detects added files" do
      repo = make_repo()
      {sha_a, repo} = make_tree(repo, [])
      {sha_b, repo} = make_tree(repo, [{"file.txt", "hello\n"}])

      assert {:ok, [%{op: :added, path: "file.txt"}]} = Diff.trees(repo, sha_a, sha_b)
    end

    test "detects removed files" do
      repo = make_repo()
      {sha_a, repo} = make_tree(repo, [{"file.txt", "hello\n"}])
      {sha_b, repo} = make_tree(repo, [])

      assert {:ok, [%{op: :removed, path: "file.txt"}]} = Diff.trees(repo, sha_a, sha_b)
    end

    test "detects modified files" do
      repo = make_repo()
      {sha_a, repo} = make_tree(repo, [{"file.txt", "hello\n"}])
      {sha_b, repo} = make_tree(repo, [{"file.txt", "world\n"}])

      assert {:ok, [%{op: :modified, path: "file.txt"}]} = Diff.trees(repo, sha_a, sha_b)
    end

    test "ignores unchanged files" do
      repo = make_repo()
      {sha_a, repo} = make_tree(repo, [{"a.txt", "same"}, {"b.txt", "v1"}])
      {sha_b, repo} = make_tree(repo, [{"a.txt", "same"}, {"b.txt", "v2"}])

      assert {:ok, [%{op: :modified, path: "b.txt"}]} = Diff.trees(repo, sha_a, sha_b)
    end

    test "recurses into subdirectories" do
      repo = make_repo()
      {sha_a, repo} = make_tree(repo, [{"dir", :tree, [{"nested.txt", "old\n"}]}])
      {sha_b, repo} = make_tree(repo, [{"dir", :tree, [{"nested.txt", "new\n"}]}])

      assert {:ok, [%{op: :modified, path: "dir/nested.txt"}]} = Diff.trees(repo, sha_a, sha_b)
    end

    test "detects added subdirectory" do
      repo = make_repo()
      {sha_a, repo} = make_tree(repo, [])
      {sha_b, repo} = make_tree(repo, [{"dir", :tree, [{"a.txt", "a"}, {"b.txt", "b"}]}])

      assert {:ok, changes} = Diff.trees(repo, sha_a, sha_b)
      paths = Enum.map(changes, & &1.path)
      assert "dir/a.txt" in paths
      assert "dir/b.txt" in paths
      assert Enum.all?(changes, fn c -> c.op == :added end)
    end

    test "comparing nil tree to a tree returns all added" do
      repo = make_repo()
      {sha, repo} = make_tree(repo, [{"f.txt", "data"}])

      assert {:ok, [%{op: :added, path: "f.txt"}]} = Diff.trees(repo, nil, sha)
    end

    test "comparing a tree to nil returns all removed" do
      repo = make_repo()
      {sha, repo} = make_tree(repo, [{"f.txt", "data"}])

      assert {:ok, [%{op: :removed, path: "f.txt"}]} = Diff.trees(repo, sha, nil)
    end
  end
end
