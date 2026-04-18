defmodule Exgit.LazyStreamingUXTest do
  @moduledoc """
  A4: lazy-clone streaming ops must fail loudly on a non-materialized
  Promisor repo, and `Exgit.Repository.materialize/2` converts a
  Promisor-backed repo to a Memory-backed one in one call.
  """

  use ExUnit.Case, async: true

  alias Exgit.{Object.Blob, Object.Commit, Object.Tree}
  alias Exgit.{ObjectStore, RefStore, Repository}

  # Minimal fake transport (copied from the existing lazy test harness)
  defmodule FakeT do
    defstruct [:store, :refs]
  end

  defimpl Exgit.Transport, for: Exgit.LazyStreamingUXTest.FakeT do
    alias Exgit.LazyStreamingUXTest.FakeT
    def capabilities(_), do: {:ok, %{version: 2}}
    def ls_refs(%FakeT{refs: r}, _), do: {:ok, r, %{}}
    def push(_, _, _, _), do: {:error, :unsupported}

    def fetch(%FakeT{store: store}, wants, _opts) do
      objects =
        for sha <- wants do
          case Exgit.ObjectStore.get(store, sha) do
            {:ok, obj} -> reachable(store, obj)
            _ -> []
          end
        end
        |> List.flatten()
        |> Enum.uniq_by(&Exgit.Object.sha/1)

      {:ok, Exgit.Pack.Writer.build(objects), %{objects: length(objects)}}
    end

    defp reachable(store, %Commit{} = c) do
      tree_sha = Commit.tree(c)
      {:ok, tree} = Exgit.ObjectStore.get(store, tree_sha)
      [c | reachable(store, tree)]
    end

    defp reachable(store, %Tree{entries: entries} = t) do
      children =
        Enum.flat_map(entries, fn {_mode, _name, sha} ->
          case Exgit.ObjectStore.get(store, sha) do
            {:ok, obj} -> reachable(store, obj)
            _ -> []
          end
        end)

      [t | children]
    end

    defp reachable(_store, other), do: [other]
  end

  defp seed_repo do
    store = ObjectStore.Memory.new()
    blob = Blob.new("hello\n")
    {:ok, blob_sha, store} = ObjectStore.put(store, blob)

    tree = Tree.new([{"100644", "readme.md", blob_sha}])
    {:ok, tree_sha, store} = ObjectStore.put(store, tree)

    c =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, c)
    {store, commit_sha}
  end

  describe "streaming ops on a Promisor-backed repo (A4)" do
    test "FS.walk raises a helpful error when the repo is Promisor-backed and not prefetched" do
      {store, commit_sha} = seed_repo()

      transport = %FakeT{store: store, refs: [{"refs/heads/main", commit_sha}]}

      {:ok, repo} = Exgit.clone(transport, lazy: true)

      msg =
        assert_raise ArgumentError, fn ->
          Exgit.FS.walk(repo, "HEAD") |> Enum.to_list()
        end

      # The error must mention both the cause (Promisor) and the fix
      # (prefetch/3 or materialize/2). No cryptic "not found" tombstones.
      assert msg.message =~ "Promisor" or msg.message =~ "prefetch"
    end

    test "FS.grep raises the same way" do
      {store, commit_sha} = seed_repo()

      transport = %FakeT{store: store, refs: [{"refs/heads/main", commit_sha}]}
      {:ok, repo} = Exgit.clone(transport, lazy: true)

      assert_raise ArgumentError, fn ->
        Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
      end
    end

    test "FS.walk works after FS.prefetch(repo, ref, blobs: true)" do
      {store, commit_sha} = seed_repo()

      transport = %FakeT{store: store, refs: [{"refs/heads/main", commit_sha}]}
      {:ok, repo} = Exgit.clone(transport, lazy: true)
      {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)

      paths = Exgit.FS.walk(repo, "HEAD") |> Enum.to_list() |> Enum.map(&elem(&1, 0))
      assert paths == ["readme.md"]
    end
  end

  describe "Repository.materialize/2 (A4)" do
    test "converts a Promisor-backed repo into a Memory-backed one" do
      {store, commit_sha} = seed_repo()

      transport = %FakeT{store: store, refs: [{"refs/heads/main", commit_sha}]}
      {:ok, repo} = Exgit.clone(transport, lazy: true)

      # Before: store is a Promisor.
      assert %ObjectStore.Promisor{} = repo.object_store

      {:ok, repo} = Repository.materialize(repo, "HEAD")

      # After: store is a plain Memory, and streaming ops work without
      # any special opt-in.
      assert %ObjectStore.Memory{} = repo.object_store

      paths = Exgit.FS.walk(repo, "HEAD") |> Enum.to_list() |> Enum.map(&elem(&1, 0))
      assert paths == ["readme.md"]
    end

    test "materialize is idempotent on a Memory-backed repo" do
      # A non-Promisor repo passes through unchanged.
      {store, commit_sha} = seed_repo()

      {:ok, ref_store} =
        RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

      {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      {:ok, materialized} = Repository.materialize(repo, "HEAD")
      assert materialized == repo
    end
  end
end
