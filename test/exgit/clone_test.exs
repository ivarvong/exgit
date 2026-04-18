defmodule Exgit.CloneTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore}

  setup do
    base = Path.join(System.tmp_dir!(), "exgit_clone_#{System.unique_integer([:positive])}")
    origin_path = Path.join(base, "origin.git")
    clone_path = Path.join(base, "clone.git")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, origin_path: origin_path, clone_path: clone_path}
  end

  defp seed_origin(path) do
    {:ok, _repo} = Exgit.init(path: path)
    store = ObjectStore.Disk.new(path)

    blob = Blob.new("origin content\n")
    {:ok, blob_sha} = ObjectStore.Disk.put_object(store, blob)

    tree = Tree.new([{"100644", "readme.txt", blob_sha}])
    {:ok, tree_sha} = ObjectStore.Disk.put_object(store, tree)

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "Origin <o@o.com> 1000000000 +0000",
        committer: "Origin <o@o.com> 1000000000 +0000",
        message: "initial\n"
      )

    {:ok, commit_sha} = ObjectStore.Disk.put_object(store, commit)
    :ok = RefStore.Disk.write_ref(RefStore.Disk.new(path), "refs/heads/main", commit_sha)
    commit_sha
  end

  describe "clone via file transport" do
    test "clones to disk", %{origin_path: origin, clone_path: clone} do
      commit_sha = seed_origin(origin)
      transport = Exgit.Transport.File.new(origin)

      assert {:ok, repo} = Exgit.clone(transport, path: clone)

      assert {:ok, %Commit{message: "initial\n"}} =
               Exgit.ObjectStore.get(repo.object_store, commit_sha)

      assert {:ok, {:symbolic, "refs/heads/main"}} =
               Exgit.RefStore.read(repo.ref_store, "HEAD")

      assert {:ok, ^commit_sha} =
               Exgit.RefStore.resolve(repo.ref_store, "HEAD")
    end

    test "clones to memory", %{origin_path: origin} do
      commit_sha = seed_origin(origin)
      transport = Exgit.Transport.File.new(origin)

      assert {:ok, repo} = Exgit.clone(transport)
      assert %ObjectStore.Memory{} = repo.object_store

      assert {:ok, %Commit{message: "initial\n"}} =
               Exgit.ObjectStore.get(repo.object_store, commit_sha)

      assert {:ok, ^commit_sha} =
               Exgit.RefStore.resolve(repo.ref_store, "HEAD")
    end

    @tag :git_cross_check
    test "cloned repo passes git fsck", %{origin_path: origin, clone_path: clone} do
      seed_origin(origin)
      transport = Exgit.Transport.File.new(origin)

      assert {:ok, _repo} = Exgit.clone(transport, path: clone)

      {output, status} = System.cmd("git", ["fsck"], cd: clone, stderr_to_stdout: true)
      assert status == 0, "git fsck failed: #{output}"
    end
  end

  describe "push via file transport" do
    test "pushes a new commit", %{origin_path: origin, clone_path: clone} do
      seed_origin(origin)
      transport = Exgit.Transport.File.new(origin)
      {:ok, repo} = Exgit.clone(transport, path: clone)

      store = repo.object_store
      blob = Blob.new("new content\n")
      {:ok, blob_sha} = ObjectStore.Disk.put_object(store, blob)
      tree = Tree.new([{"100644", "new.txt", blob_sha}])
      {:ok, tree_sha} = ObjectStore.Disk.put_object(store, tree)

      {:ok, parent_sha} = RefStore.Disk.resolve_ref(repo.ref_store, "refs/heads/main")

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [parent_sha],
          author: "Clone <c@c.com> 2000000000 +0000",
          committer: "Clone <c@c.com> 2000000000 +0000",
          message: "from clone\n"
        )

      {:ok, commit_sha} = ObjectStore.Disk.put_object(store, commit)
      :ok = RefStore.Disk.write_ref(repo.ref_store, "refs/heads/main", commit_sha)

      assert {:ok, %{ref_results: _}} =
               Exgit.push(repo, transport, refspecs: ["refs/heads/main"])

      assert {:ok, ^commit_sha} =
               RefStore.Disk.read_ref(RefStore.Disk.new(origin), "refs/heads/main")
    end
  end
end
