defmodule Exgit.PromisorStatelessTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore
  alias Exgit.ObjectStore.Promisor

  @moduledoc """
  The Promisor is a pure value — no processes, no pids, no Agent. Two
  callers holding the same %Promisor{} must see exactly the cache it
  carries at that point in time. Growing the cache requires the caller
  to thread the updated struct through via `Promisor.resolve/2`.
  """

  # Minimal FakeTransport for these tests.
  defmodule FakeT do
    defstruct [:store, :calls]

    def new(store), do: %__MODULE__{store: store, calls: []}
  end

  defimpl Exgit.Transport, for: Exgit.PromisorStatelessTest.FakeT do
    alias Exgit.PromisorStatelessTest.FakeT

    def capabilities(_), do: {:ok, %{version: 2}}
    def ls_refs(_, _), do: {:ok, [], %{}}
    def push(_, _, _, _), do: {:error, :unsupported}

    def fetch(%FakeT{store: store}, wants, _opts) do
      objects =
        for sha <- wants do
          case Exgit.ObjectStore.get(store, sha) do
            {:ok, obj} -> obj
            _ -> nil
          end
        end
        |> Enum.reject(&is_nil/1)

      {:ok, Exgit.Pack.Writer.build(objects), %{objects: length(objects)}}
    end
  end

  defp origin_with_blob do
    store = ObjectStore.Memory.new()
    blob = Blob.new("stateless\n")
    {:ok, sha, store} = ObjectStore.put(store, blob)
    {store, sha, blob}
  end

  describe "Promisor is a pure struct (no process)" do
    test "Promisor.new returns a struct with no pid fields" do
      {origin, _sha, _blob} = origin_with_blob()
      p = Promisor.new(FakeT.new(origin))

      refute Map.has_key?(p, :cache) and is_pid(Map.get(p, :cache)),
             "Promisor must not hold a pid — got #{inspect(p)}"
    end

    test "two processes holding the same struct see the same cache" do
      {origin, _sha, _blob} = origin_with_blob()
      p = Promisor.new(FakeT.new(origin))

      parent = self()

      Task.async(fn -> send(parent, {:sibling, p}) end) |> Task.await()

      assert_receive {:sibling, received}
      assert received == p, "same struct should round-trip through a message send"
    end

    test "Promisor is comparable by value" do
      {origin, _sha, _blob} = origin_with_blob()
      a = Promisor.new(FakeT.new(origin))
      b = Promisor.new(FakeT.new(origin))

      # Both contain equivalent state → equal.
      assert a == b
    end
  end

  describe "Promisor.resolve/2 — the cache-growing API" do
    test "returns {:ok, object, new_promisor} on cache miss and network fetch" do
      {origin, sha, blob} = origin_with_blob()
      p = Promisor.new(FakeT.new(origin))

      assert {:ok, ^blob, p2} = Promisor.resolve(p, sha)
      assert Promisor.has_object?(p2, sha)
      refute Promisor.has_object?(p, sha), "original Promisor must be unchanged"
    end

    test "returns {:ok, object, same_promisor} on cache hit" do
      {origin, sha, blob} = origin_with_blob()
      p = Promisor.new(FakeT.new(origin))

      {:ok, ^blob, p1} = Promisor.resolve(p, sha)
      {:ok, ^blob, p2} = Promisor.resolve(p1, sha)

      # Second call didn't grow the cache — p1 == p2.
      assert p1 == p2
    end

    test "returns {:error, :not_found, promisor} when remote doesn't have the object" do
      # The cache-growing API threads the promisor back even on the
      # fetch-but-not-found path so sibling objects that came back
      # in the same pack aren't discarded. See `Promisor.resolve/2`
      # docstring for the error-shape contract.
      {origin, _sha, _blob} = origin_with_blob()
      p = Promisor.new(FakeT.new(origin))

      missing = :binary.copy(<<0xCC>>, 20)

      assert {:error, :not_found, %Promisor{}} =
               Promisor.resolve(p, missing)
    end
  end

  describe "ObjectStore.get/2 remains pure-read on a Promisor" do
    test "get/2 reads the cache but does NOT grow it" do
      {origin, sha, _blob} = origin_with_blob()
      p = Promisor.new(FakeT.new(origin))

      # Nothing cached yet. get/2 returns :not_found — no fetch.
      assert {:error, :not_found} = ObjectStore.get(p, sha)
      refute Promisor.has_object?(p, sha)
    end

    test "get/2 on a cached sha returns it" do
      {origin, sha, blob} = origin_with_blob()
      p = Promisor.new(FakeT.new(origin))

      {:ok, ^blob, p2} = Promisor.resolve(p, sha)
      assert {:ok, ^blob} = ObjectStore.get(p2, sha)
    end
  end

  describe "FS threads the updated repo through strict operations" do
    setup do
      # Build a tiny repo on an origin store, wrap in a Promisor.
      store = ObjectStore.Memory.new()

      b1 = Blob.new("hello\n")
      {:ok, b1_sha, store} = ObjectStore.put(store, b1)

      tree = Tree.new([{"100644", "readme.md", b1_sha}])
      {:ok, tree_sha, store} = ObjectStore.put(store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "init\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      promisor = Promisor.new(FakeT.new(store))

      {:ok, rs} =
        Exgit.RefStore.write(Exgit.RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

      {:ok, rs} = Exgit.RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Exgit.Repository{
        object_store: promisor,
        ref_store: rs,
        config: Exgit.Config.new(),
        path: nil
      }

      {:ok, repo: repo, commit_sha: commit_sha, tree_sha: tree_sha, blob_sha: b1_sha}
    end

    test "FS.read_path returns {:ok, result, repo} and the returned repo has the cache grown",
         %{repo: repo, blob_sha: blob_sha} do
      assert {:ok, {_mode, %Blob{data: "hello\n"}}, repo2} =
               Exgit.FS.read_path(repo, "HEAD", "readme.md")

      # The original repo's store didn't mutate.
      refute Promisor.has_object?(repo.object_store, blob_sha),
             "original repo's cache must be unchanged"

      # The returned repo has the blob cached.
      assert Promisor.has_object?(repo2.object_store, blob_sha)
    end

    test "FS.ls returns {:ok, entries, repo}", %{repo: repo} do
      assert {:ok, entries, _repo2} = Exgit.FS.ls(repo, "HEAD", "")
      assert [{_mode, "readme.md", _sha}] = entries
    end
  end
end
