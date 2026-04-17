defmodule Exgit.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  @repo_url "https://github.com/elixir-ai-tools/just_bash"

  describe "clone public repo into memory" do
    test "clones just_bash and reads a file" do
      assert {:ok, repo} = Exgit.clone(@repo_url)

      assert %Exgit.ObjectStore.Memory{} = repo.object_store

      {:ok, head_sha} = Exgit.RefStore.resolve(repo.ref_store, "HEAD")
      {:ok, commit} = Exgit.ObjectStore.get(repo.object_store, head_sha)
      assert %Exgit.Object.Commit{} = commit

      {:ok, content} =
        read_file(repo, Exgit.Object.Commit.tree(commit), "lib/just_bash/interpreter/executor.ex")

      assert content =~ "defmodule"
      assert content =~ "JustBash"
    end
  end

  defp read_file(repo, tree_sha, path) do
    segments = String.split(path, "/")
    walk_tree(repo, tree_sha, segments)
  end

  defp walk_tree(repo, tree_sha, [name]) do
    {:ok, tree} = Exgit.ObjectStore.get(repo.object_store, tree_sha)

    case Enum.find(tree.entries, fn {_mode, n, _sha} -> n == name end) do
      {_mode, _name, blob_sha} ->
        {:ok, blob} = Exgit.ObjectStore.get(repo.object_store, blob_sha)
        {:ok, blob.data}

      nil ->
        {:error, :not_found}
    end
  end

  defp walk_tree(repo, tree_sha, [dir | rest]) do
    {:ok, tree} = Exgit.ObjectStore.get(repo.object_store, tree_sha)

    case Enum.find(tree.entries, fn {_mode, n, _sha} -> n == dir end) do
      {_mode, _name, subtree_sha} -> walk_tree(repo, subtree_sha, rest)
      nil -> {:error, :not_found}
    end
  end
end
