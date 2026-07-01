defmodule Exgit.FsSizeTest do
  use ExUnit.Case, async: true

  alias Exgit.{FS, ObjectStore, RefStore, Repository}
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore.{Disk, Memory, Promisor}

  describe "Memory.object_size/2" do
    test "matches byte_size of the content across sizes, regardless of compressibility" do
      for data <- [
            "",
            "hello\n",
            String.duplicate("a", 100_000),
            :crypto.strong_rand_bytes(1_000_000)
          ] do
        store = Memory.new()
        {:ok, sha, store} = ObjectStore.put(store, Blob.new(data))
        assert ObjectStore.object_size(store, sha) == {:ok, byte_size(data)}
      end
    end

    test "returns :not_found for an absent sha" do
      assert ObjectStore.object_size(Memory.new(), :crypto.strong_rand_bytes(20)) ==
               {:error, :not_found}
    end

    test "import_objects populates the size index" do
      data = "imported\n"
      {sha, content} = {raw_blob_sha(data), data}
      {:ok, store} = ObjectStore.import_objects(Memory.new(), [{:blob, sha, content}])
      assert ObjectStore.object_size(store, sha) == {:ok, byte_size(data)}
    end

    test "streaming write records the actual (summed) size, not the declared one" do
      store = Memory.new()
      # Declare 0 on purpose: the index must reflect bytes actually written.
      {:ok, h} = ObjectStore.open_write(store, :blob, 0)
      {:ok, h} = ObjectStore.write_chunk(store, h, "abc")
      {:ok, h} = ObjectStore.write_chunk(store, h, "de")
      {:ok, sha, store} = ObjectStore.close_write(store, h)

      assert ObjectStore.object_size(store, sha) == {:ok, 5}
    end
  end

  describe "Promisor.object_size/2 (never fetches)" do
    test "returns the size for a locally cached object" do
      blob = Blob.new("cached body\n")
      # `:no_transport` is never used: object_size only reads the cache.
      promisor = Promisor.new(:no_transport, initial_objects: [blob])
      sha = Blob.sha(blob)

      assert ObjectStore.object_size(promisor, sha) == {:ok, byte_size("cached body\n")}
    end

    test "returns :not_local for an un-fetched object and does NOT touch the transport" do
      # The transport is a bare atom with no Transport impl: if object_size
      # tried to fetch, the call would crash. A clean :not_local proves it didn't.
      promisor = Promisor.new(:boom_if_used, initial_objects: [])
      absent = :crypto.strong_rand_bytes(20)

      assert ObjectStore.object_size(promisor, absent) == {:error, :not_local}
    end
  end

  describe "Disk.object_size/2" do
    test "reads loose-object size from the header" do
      dir = Path.join(System.tmp_dir!(), "exgit_size_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      data = String.duplicate("x", 250_000)
      store = Disk.new(dir)
      {:ok, sha, store} = ObjectStore.put(store, Blob.new(data))

      assert ObjectStore.object_size(store, sha) == {:ok, byte_size(data)}
    end
  end

  describe "FS.size/3" do
    setup do
      store = Memory.new()

      readme = Blob.new("hello world\n")
      {:ok, readme_sha, store} = ObjectStore.put(store, readme)

      nested = Blob.new("deep\n")
      {:ok, nested_sha, store} = ObjectStore.put(store, nested)

      nested_tree = Tree.new([{"100644", "c.txt", nested_sha}])
      {:ok, nested_tree_sha, store} = ObjectStore.put(store, nested_tree)

      src_tree = Tree.new([{"40000", "deep", nested_tree_sha}])
      {:ok, src_sha, store} = ObjectStore.put(store, src_tree)

      # Gitlink (submodule) entry: the SHA names a commit in the
      # submodule's OWN repository, so it is never present in this
      # object store — exactly the situation size/3 must not treat
      # as a missing local object.
      submodule_commit_sha = :crypto.strong_rand_bytes(20)

      root =
        Tree.new([
          {"100644", "README.md", readme_sha},
          {"160000", "vendored", submodule_commit_sha},
          {"40000", "src", src_sha}
        ])

      {:ok, root_sha, store} = ObjectStore.put(store, root)

      commit =
        Commit.new(
          tree: root_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "init\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)
      {:ok, refs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
      {:ok, refs} = RefStore.write(refs, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Repository{
        object_store: store,
        ref_store: refs,
        config: Exgit.Config.new(),
        path: nil
      }

      {:ok, repo: repo}
    end

    test "returns the blob size for a top-level file", %{repo: repo} do
      assert {:ok, size, %Repository{}} = FS.size(repo, "HEAD", "README.md")
      assert size == byte_size("hello world\n")
    end

    test "returns the blob size for a nested file", %{repo: repo} do
      assert {:ok, 5, %Repository{}} = FS.size(repo, "HEAD", "src/deep/c.txt")
    end

    test "matches read_path's blob byte_size", %{repo: repo} do
      {:ok, {_mode, %Blob{data: data}}, _repo} = FS.read_path(repo, "HEAD", "README.md")
      assert {:ok, byte_size(data), repo} == FS.size(repo, "HEAD", "README.md")
    end

    test "rejects directories with :not_a_blob", %{repo: repo} do
      assert FS.size(repo, "HEAD", "src") == {:error, :not_a_blob}
    end

    test "returns :submodule for a gitlink entry instead of a doomed lookup", %{repo: repo} do
      # Before the short-circuit, this fell through to an
      # object_size lookup of the submodule's commit SHA and
      # surfaced a misleading :not_found / :not_local.
      assert FS.size(repo, "HEAD", "vendored") == {:error, :submodule}
    end

    test "read_path and stat agree on gitlink handling", %{repo: repo} do
      # read_path must fail the same way as size/3 — before any
      # object lookup of the submodule's commit SHA...
      assert FS.read_path(repo, "HEAD", "vendored") == {:error, :submodule}

      # ...while stat reports the entry without fetching anything.
      assert {:ok, %{type: :submodule, mode: "160000", size: nil}, %Repository{}} =
               FS.stat(repo, "HEAD", "vendored")
    end

    test "returns :not_found for a missing path", %{repo: repo} do
      assert FS.size(repo, "HEAD", "nope.txt") == {:error, :not_found}
    end
  end

  describe "FS.size/3 on a lazy clone" do
    test "returns :not_local without fetching the blob" do
      # Seed a Promisor cache with the commit + trees, but NOT the blob.
      # `walk_path` resolves the path through cached trees; the blob's size
      # is reported as :not_local rather than triggering a transport fetch.
      store = Memory.new()
      blob = Blob.new("would be huge\n")
      blob_sha = Blob.sha(blob)
      root = Tree.new([{"100644", "big.bin", blob_sha}])
      {:ok, root_sha, store} = ObjectStore.put(store, root)

      commit =
        Commit.new(
          tree: root_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "init\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      # Cache holds commit + root tree only — the blob is deliberately absent.
      {:ok, commit_obj} = ObjectStore.get(store, commit_sha)
      {:ok, root_obj} = ObjectStore.get(store, root_sha)
      promisor = Promisor.new(:boom_if_used, initial_objects: [commit_obj, root_obj])

      {:ok, refs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
      {:ok, refs} = RefStore.write(refs, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Repository{
        object_store: promisor,
        ref_store: refs,
        config: Exgit.Config.new(),
        path: nil
      }

      assert FS.size(repo, "HEAD", "big.bin") == {:error, :not_local}
    end
  end

  # Compute a blob sha the same way the store does, for import_objects tests.
  defp raw_blob_sha(data), do: Blob.sha(Blob.new(data))
end
