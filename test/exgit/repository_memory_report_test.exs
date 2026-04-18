defmodule Exgit.RepositoryMemoryReportTest do
  @moduledoc """
  Tests `Exgit.Repository.memory_report/1` across the object-store
  backends we actually ship: `Memory` and `Promisor`. `Disk` and
  user-defined stores get a degraded report (placeholders); we
  assert that the shape is consistent across all backends so
  callers can depend on the keys existing.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore
  alias Exgit.Repository

  describe "on a Memory-backed eager repo" do
    setup do
      store = ObjectStore.Memory.new()

      {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new("content\n"))

      {:ok, tree_sha, store} =
        ObjectStore.put(store, Tree.new([{"100644", "a.txt", blob_sha}]))

      c =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "A <a@a.com> 1 +0000",
          committer: "A <a@a.com> 1 +0000",
          message: "one\n"
        )

      {:ok, _c_sha, store} = ObjectStore.put(store, c)

      repo = Repository.new(store, Exgit.RefStore.Memory.new())
      {:ok, repo: repo}
    end

    test "counts objects by type", %{repo: repo} do
      report = Repository.memory_report(repo)

      assert report.object_count == 3
      assert report.blob_count == 1
      assert report.tree_count == 1
      assert report.commit_count == 1
      assert report.tag_count == 0
    end

    test "reports compressed cache_bytes > 0", %{repo: repo} do
      report = Repository.memory_report(repo)
      assert report.cache_bytes > 0
    end

    test "reports :eager mode", %{repo: repo} do
      report = Repository.memory_report(repo)
      assert report.mode == :eager
    end

    test "reports Memory backend", %{repo: repo} do
      report = Repository.memory_report(repo)
      assert report.backend == ObjectStore.Memory
    end

    test "reports :infinity max_cache_bytes for Memory", %{repo: repo} do
      # Memory has no concept of a cap; always :infinity.
      report = Repository.memory_report(repo)
      assert report.max_cache_bytes == :infinity
    end
  end

  describe "on a Promisor-backed lazy repo" do
    # A Promisor with pre-seeded objects (no real transport).
    # Covers the branch of memory_report/1 that introspects the
    # Promisor struct's cache_bytes + max_cache_bytes fields.
    setup do
      store =
        ObjectStore.Promisor.new(
          %{__struct__: FakeTransport},
          initial_objects: [Blob.new("hello\n"), Blob.new("world\n")]
        )

      repo = Repository.new(store, Exgit.RefStore.Memory.new(), mode: :lazy)
      {:ok, repo: repo}
    end

    test "reports object count from the Promisor's internal cache", %{repo: repo} do
      report = Repository.memory_report(repo)
      assert report.object_count == 2
      assert report.blob_count == 2
    end

    test "reports :lazy mode", %{repo: repo} do
      report = Repository.memory_report(repo)
      assert report.mode == :lazy
    end

    test "reports Promisor backend", %{repo: repo} do
      report = Repository.memory_report(repo)
      assert report.backend == ObjectStore.Promisor
    end

    test "max_cache_bytes reflects the Promisor's configured cap" do
      # Promisor.new/2 with an explicit cap → report reflects it.
      store =
        ObjectStore.Promisor.new(%{__struct__: FakeTransport}, max_cache_bytes: 64 * 1024 * 1024)

      repo = Repository.new(store, Exgit.RefStore.Memory.new(), mode: :lazy)
      report = Repository.memory_report(repo)

      assert report.max_cache_bytes == 64 * 1024 * 1024
    end
  end

  describe "shape invariants" do
    test "report always has the same keys regardless of backend" do
      # Memory-backed
      empty_memory = Repository.new(ObjectStore.Memory.new(), Exgit.RefStore.Memory.new())
      memory_keys = empty_memory |> Repository.memory_report() |> Map.keys() |> Enum.sort()

      # Promisor-backed (empty)
      empty_promisor_store =
        ObjectStore.Promisor.new(%{__struct__: FakeTransport}, initial_objects: [])

      empty_promisor =
        Repository.new(empty_promisor_store, Exgit.RefStore.Memory.new(), mode: :lazy)

      promisor_keys = empty_promisor |> Repository.memory_report() |> Map.keys() |> Enum.sort()

      assert memory_keys == promisor_keys
    end
  end
end
