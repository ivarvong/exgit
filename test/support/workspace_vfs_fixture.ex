defmodule Exgit.Test.WorkspaceVFSFixture do
  @moduledoc false
  # Backend factory for the VFS conformance test against `Exgit.Workspace`.
  # Lives in test/support so it's compiled once and stays on the load path
  # for every conformance run.

  alias Exgit.Object.{Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Workspace}

  @doc """
  Build an empty in-memory repo (root tree with no entries) and open
  a workspace over it. Conformance tests write into the fresh tree and
  assert reads/walks reflect them — so the starting state is empty.
  """
  def fresh do
    store = ObjectStore.Memory.new()

    {:ok, root_sha, store} = ObjectStore.put(store, Tree.new([]))

    commit =
      Commit.new(
        tree: root_sha,
        parents: [],
        author: "T <t@t> 0 +0000",
        committer: "T <t@t> 0 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)
    {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
    {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = Repository.new(store, ref_store)
    Workspace.open(repo, "refs/heads/main")
  end
end
