defmodule Exgit.Transport.FileTest do
  use ExUnit.Case, async: true

  alias Exgit.Transport.File, as: FileTransport
  alias Exgit.{ObjectStore, RefStore}
  alias Exgit.Object.{Blob, Tree, Commit}

  setup do
    path =
      Path.join(System.tmp_dir!(), "exgit_file_transport_#{System.unique_integer([:positive])}")

    {:ok, _repo} = Exgit.init(path: path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{path: path}
  end

  defp seed_repo(path) do
    store = ObjectStore.Disk.new(path)
    ref_store = RefStore.Disk.new(path)

    blob = Blob.new("hello\n")
    {:ok, blob_sha} = ObjectStore.Disk.put_object(store, blob)

    tree = Tree.new([{"100644", "hello.txt", blob_sha}])
    {:ok, tree_sha} = ObjectStore.Disk.put_object(store, tree)

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "Test <t@t.com> 1000000000 +0000",
        committer: "Test <t@t.com> 1000000000 +0000",
        message: "init\n"
      )

    {:ok, commit_sha} = ObjectStore.Disk.put_object(store, commit)
    :ok = RefStore.Disk.write_ref(ref_store, "refs/heads/main", commit_sha)
    commit_sha
  end

  describe "ls_refs/2" do
    test "lists refs from a bare repo", %{path: path} do
      commit_sha = seed_repo(path)
      transport = FileTransport.new(path)

      assert {:ok, refs} = FileTransport.ls_refs(transport)
      assert {"refs/heads/main", ^commit_sha} = List.keyfind(refs, "refs/heads/main", 0)
    end
  end

  describe "fetch/3" do
    test "fetches objects as a packfile", %{path: path} do
      commit_sha = seed_repo(path)
      transport = FileTransport.new(path)

      assert {:ok, pack_data, _summary} = FileTransport.fetch(transport, [commit_sha])
      assert byte_size(pack_data) > 0
      assert {:ok, objects} = Exgit.Pack.Reader.parse(pack_data)
      assert length(objects) >= 3
    end
  end

  describe "push/4" do
    test "pushes objects and updates refs", %{path: path} do
      seed_repo(path)
      transport = FileTransport.new(path)

      store = ObjectStore.Disk.new(path)
      blob = Blob.new("pushed\n")
      {:ok, blob_sha} = ObjectStore.Disk.put_object(store, blob)
      tree = Tree.new([{"100644", "pushed.txt", blob_sha}])
      {:ok, tree_sha} = ObjectStore.Disk.put_object(store, tree)

      {:ok, [{_, main_sha}]} =
        FileTransport.ls_refs(transport, prefix: "refs/heads/")

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [main_sha],
          author: "Test <t@t.com> 2000000000 +0000",
          committer: "Test <t@t.com> 2000000000 +0000",
          message: "push test\n"
        )

      {:ok, commit_sha} = ObjectStore.Disk.put_object(store, commit)

      pack = Exgit.Pack.Writer.build([blob, tree, commit])

      assert {:ok, %{ref_results: results}} =
               FileTransport.push(
                 transport,
                 [{"refs/heads/main", main_sha, commit_sha}],
                 pack
               )

      assert {"refs/heads/main", :ok} in results

      assert {:ok, ^commit_sha} =
               RefStore.Disk.read_ref(RefStore.Disk.new(path), "refs/heads/main")
    end
  end
end
