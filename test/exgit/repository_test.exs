defmodule Exgit.RepositoryTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository}

  describe "in-memory repository" do
    test "creates and queries objects entirely in memory" do
      repo = Repository.new(ObjectStore.Memory.new(), RefStore.Memory.new())

      blob = Blob.new("hello\n")
      {:ok, blob_sha, store} = ObjectStore.Memory.put_object(repo.object_store, blob)
      repo = %{repo | object_store: store}

      tree = Tree.new([{"100644", "hello.txt", blob_sha}])
      {:ok, tree_sha, store} = ObjectStore.Memory.put_object(repo.object_store, tree)
      repo = %{repo | object_store: store}

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "Test <t@t.com> 1000000000 +0000",
          committer: "Test <t@t.com> 1000000000 +0000",
          message: "init\n"
        )

      {:ok, commit_sha, store} = ObjectStore.Memory.put_object(repo.object_store, commit)
      repo = %{repo | object_store: store}

      {:ok, ref_store} = RefStore.Memory.write_ref(repo.ref_store, "refs/heads/main", commit_sha)

      {:ok, ref_store} =
        RefStore.Memory.write_ref(ref_store, "HEAD", {:symbolic, "refs/heads/main"})

      repo = %{repo | ref_store: ref_store}

      assert {:ok, ^commit_sha} = RefStore.Memory.resolve_ref(repo.ref_store, "HEAD")
      assert {:ok, %Commit{}} = ObjectStore.Memory.get_object(repo.object_store, commit_sha)
    end
  end

  describe "init/1" do
    setup do
      path = Path.join(System.tmp_dir!(), "exgit_init_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(path) end)
      %{path: path}
    end

    test "creates a valid bare repository on disk", %{path: path} do
      assert {:ok, repo} = Exgit.init(path: path)
      assert repo.path == path

      assert File.exists?(Path.join(path, "HEAD"))
      assert File.dir?(Path.join(path, "objects"))
      assert File.dir?(Path.join(path, "refs/heads"))
    end

    test "creates an in-memory repository by default" do
      assert {:ok, repo} = Exgit.init()
      assert %ObjectStore.Memory{} = repo.object_store
      assert %RefStore.Memory{} = repo.ref_store
      assert repo.path == nil
    end

    @tag :git_cross_check
    test "passes git fsck", %{path: path} do
      assert {:ok, _repo} = Exgit.init(path: path)

      {output, status} = System.cmd("git", ["fsck"], cd: path, stderr_to_stdout: true)
      assert status == 0, "git fsck failed: #{output}"
    end
  end

  describe "open/1" do
    setup do
      path = Path.join(System.tmp_dir!(), "exgit_open_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(path) end)
      %{path: path}
    end

    test "opens a repository created by init", %{path: path} do
      {:ok, _} = Exgit.init(path: path)
      assert {:ok, repo} = Exgit.open(path)
      assert repo.path == path
    end

    test "rejects a non-repository directory", %{path: path} do
      File.mkdir_p!(path)
      assert {:error, {:not_a_repository, _}} = Exgit.open(path)
    end
  end

  describe "end-to-end: write commit then verify with git" do
    @tag :git_cross_check
    test "creates a commit readable by git log" do
      path = Path.join(System.tmp_dir!(), "exgit_e2e_#{System.unique_integer([:positive])}")

      {:ok, repo} = Exgit.init(path: path)

      blob = Blob.new("hello world\n")
      {:ok, blob_sha} = ObjectStore.Disk.put_object(repo.object_store, blob)

      tree = Tree.new([{"100644", "hello.txt", blob_sha}])
      {:ok, tree_sha} = ObjectStore.Disk.put_object(repo.object_store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "Exgit Test <test@exgit.dev> 1000000000 +0000",
          committer: "Exgit Test <test@exgit.dev> 1000000000 +0000",
          message: "initial commit from exgit\n"
        )

      {:ok, commit_sha} = ObjectStore.Disk.put_object(repo.object_store, commit)
      commit_hex = Base.encode16(commit_sha, case: :lower)
      :ok = RefStore.Disk.write_ref(repo.ref_store, "refs/heads/main", commit_sha)

      {output, status} = System.cmd("git", ["fsck"], cd: path, stderr_to_stdout: true)
      assert status == 0, "git fsck failed: #{output}"

      {log, 0} = System.cmd("git", ["log", "--oneline", commit_hex], cd: path)
      assert log =~ "initial commit from exgit"

      tree_hex = Base.encode16(tree_sha, case: :lower)
      {tree_out, 0} = System.cmd("git", ["cat-file", "-p", tree_hex], cd: path)
      assert tree_out =~ "hello.txt"

      File.rm_rf!(path)
    end
  end
end
