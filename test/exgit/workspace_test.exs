defmodule Exgit.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Workspace}

  # Build a tiny repo: README.md + src/{a.ex, b.ex} + src/nested/c.ex
  setup do
    store = ObjectStore.Memory.new()

    {:ok, readme_sha, store} = ObjectStore.put(store, Blob.new("hello\n"))
    {:ok, a_sha, store} = ObjectStore.put(store, Blob.new("module A\n"))
    {:ok, b_sha, store} = ObjectStore.put(store, Blob.new("module B\n"))
    {:ok, c_sha, store} = ObjectStore.put(store, Blob.new("module C\n"))

    nested_tree = Tree.new([{"100644", "c.ex", c_sha}])
    {:ok, nested_sha, store} = ObjectStore.put(store, nested_tree)

    src_tree =
      Tree.new([
        {"100644", "a.ex", a_sha},
        {"100644", "b.ex", b_sha},
        {"40000", "nested", nested_sha}
      ])

    {:ok, src_sha, store} = ObjectStore.put(store, src_tree)

    root_tree =
      Tree.new([
        {"100644", "README.md", readme_sha},
        {"40000", "src", src_sha}
      ])

    {:ok, root_sha, store} = ObjectStore.put(store, root_tree)

    commit =
      Commit.new(
        tree: root_sha,
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)

    {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
    {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = Repository.new(store, ref_store)

    {:ok, repo: repo, commit_sha: commit_sha, root_sha: root_sha}
  end

  describe "open/2 + reads on a pristine workspace" do
    test "reads pass through to base_ref", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:ok, "hello\n", ws} = Workspace.read(ws, "README.md")
      assert {:ok, "module A\n", _ws} = Workspace.read(ws, "src/a.ex")
    end

    test "ls returns sorted names", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:ok, ["README.md", "src"], _ws} = Workspace.ls(ws, "")
      assert {:ok, ["a.ex", "b.ex", "nested"], _ws} = Workspace.ls(ws, "src")
    end

    test "stat distinguishes blob and tree", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:ok, %{type: :blob}, _} = Workspace.stat(ws, "README.md")
      assert {:ok, %{type: :tree}, _} = Workspace.stat(ws, "src")
    end

    test "exists?/2 threads state but never writes", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {true, _ws} = Workspace.exists?(ws, "README.md")
      assert {false, _ws} = Workspace.exists?(ws, "missing.ex")
    end

    test "snapshot of pristine workspace is :pristine", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert Workspace.snapshot(ws) == :pristine
    end

    test "diff of pristine workspace is empty", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:ok, [], _ws} = Workspace.diff(ws)
    end
  end

  describe "write/3" do
    test "first write sets head_tree to a real tree-sha", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "new.txt", "fresh\n")
      assert is_binary(ws.head_tree)
      assert byte_size(ws.head_tree) == 20
    end

    test "subsequent reads see the write", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "lib/foo.ex", "new content\n")
      assert {:ok, "new content\n", _ws} = Workspace.read(ws, "lib/foo.ex")
    end

    test "writes preserve unmodified files", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "src/a.ex", "changed\n")
      assert {:ok, "changed\n", ws} = Workspace.read(ws, "src/a.ex")
      assert {:ok, "module B\n", _} = Workspace.read(ws, "src/b.ex")
      assert {:ok, "hello\n", _} = Workspace.read(ws, "README.md")
    end

    test "writing onto an existing directory returns :eisdir", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:error, :eisdir} = Workspace.write(ws, "src", "no")
    end

    test "writes implicitly create parents", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "deep/path/here/file.txt", "deep\n")
      assert {:ok, "deep\n", _} = Workspace.read(ws, "deep/path/here/file.txt")
    end
  end

  describe "rm/3" do
    test "removes a top-level file", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.rm(ws, "README.md")
      assert {:error, :not_found} = Workspace.read(ws, "README.md")
    end

    test "missing path returns :not_found", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:error, :not_found} = Workspace.rm(ws, "nope")
    end

    test "directory without :recursive returns :eisdir", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:error, :eisdir} = Workspace.rm(ws, "src")
    end

    test "directory with :recursive removes contents", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.rm(ws, "src", recursive: true)
      assert {:error, :not_found} = Workspace.read(ws, "src/a.ex")
      assert {:error, :not_found} = Workspace.read(ws, "src/nested/c.ex")
      assert {:ok, "hello\n", _} = Workspace.read(ws, "README.md")
    end
  end

  describe "snapshot/1 + restore/2" do
    test "snapshot of dirty workspace is the head_tree binary", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "x.txt", "x")
      sha = Workspace.snapshot(ws)
      assert is_binary(sha)
      assert byte_size(sha) == 20
    end

    test "round-trip via restore preserves working state", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "x.txt", "v1")
      sha_after_v1 = Workspace.snapshot(ws)

      {:ok, ws} = Workspace.write(ws, "x.txt", "v2")
      assert {:ok, "v2", _} = Workspace.read(ws, "x.txt")

      ws = Workspace.restore(ws, sha_after_v1)
      assert {:ok, "v1", _} = Workspace.read(ws, "x.txt")
    end

    test "restore to :pristine resets head_tree", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "x.txt", "writes")
      ws = Workspace.restore(ws, :pristine)
      assert ws.head_tree == nil
      assert {:error, :not_found} = Workspace.read(ws, "x.txt")
    end
  end

  describe "diff/1" do
    test "lists added/modified/deleted entries", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "src/a.ex", "modified\n")
      {:ok, ws} = Workspace.write(ws, "lib/new.ex", "new file\n")
      {:ok, ws} = Workspace.rm(ws, "README.md")

      {:ok, changes, _ws} = Workspace.diff(ws)
      changes = Enum.sort(changes)

      assert {:deleted, "README.md"} in changes
      assert {:added, "lib/new.ex"} in changes
      assert {:modified, "src/a.ex"} in changes
    end
  end

  describe "commit/2" do
    test "fails with :nothing_to_commit on pristine workspace", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")

      assert {:error, :nothing_to_commit} =
               Workspace.commit(ws, message: "x", author: "a <b> 0 +0000")
    end

    test "creates a commit; returned ws reads from the new state", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "lib/foo.ex", "content\n")

      {:ok, commit_sha, ws} =
        Workspace.commit(ws,
          message: "agent: add foo",
          author: %{name: "agent", email: "a@b"}
        )

      assert is_binary(commit_sha)
      assert byte_size(commit_sha) == 20

      # head_tree cleared
      assert ws.head_tree == nil
      # base_ref now points at the new commit (sha, since update_ref: false)
      assert ws.base_ref == commit_sha

      # Reads from the new state
      assert {:ok, "content\n", _} = Workspace.read(ws, "lib/foo.ex")

      # The old branch ref was NOT advanced (update_ref: false)
      {:ok, old_main} = RefStore.resolve(repo.ref_store, "refs/heads/main")
      assert old_main != commit_sha
    end

    test "with update_ref: <name>, advances the named ref", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "lib/foo.ex", "content\n")

      {:ok, commit_sha, ws} =
        Workspace.commit(ws,
          message: "agent: add foo",
          author: %{name: "agent", email: "a@b"},
          update_ref: "refs/heads/agent-branch"
        )

      # The new ref exists in the workspace's repo
      {:ok, advanced_sha} = RefStore.resolve(ws.repo.ref_store, "refs/heads/agent-branch")
      assert advanced_sha == commit_sha
      assert ws.base_ref == "refs/heads/agent-branch"

      # Subsequent reads work via the new base_ref
      assert {:ok, "content\n", _} = Workspace.read(ws, "lib/foo.ex")
    end

    test "commit then write builds on top of the committed tree", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "a.txt", "1")
      {:ok, _sha1, ws} = Workspace.commit(ws, message: "first", author: "a <a@a> 0 +0000")

      {:ok, ws} = Workspace.write(ws, "b.txt", "2")
      {:ok, _sha2, ws} = Workspace.commit(ws, message: "second", author: "a <a@a> 0 +0000")

      assert {:ok, "1", _} = Workspace.read(ws, "a.txt")
      assert {:ok, "2", _} = Workspace.read(ws, "b.txt")
    end
  end

  describe "checkout/2" do
    test "switches base_ref and discards uncommitted writes", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "scratch.txt", "draft")

      {:ok, ws} = Workspace.checkout(ws, "refs/heads/main")
      assert ws.head_tree == nil
      assert {:error, :not_found} = Workspace.read(ws, "scratch.txt")
    end
  end

  describe "branching" do
    test "two workspaces from the same parent diverge independently", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")

      ws_a = ws
      ws_b = ws

      {:ok, ws_a} = Workspace.write(ws_a, "x.txt", "A")
      {:ok, ws_b} = Workspace.write(ws_b, "x.txt", "B")

      assert {:ok, "A", _} = Workspace.read(ws_a, "x.txt")
      assert {:ok, "B", _} = Workspace.read(ws_b, "x.txt")
    end
  end

  describe "move/3" do
    test "renames a file, preserves content and mode", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.move(ws, "src/a.ex", "src/renamed.ex")

      assert {:error, :not_found} = Workspace.read(ws, "src/a.ex")
      assert {:ok, "module A\n", _} = Workspace.read(ws, "src/renamed.ex")
    end

    test "moves into a new directory implicitly", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.move(ws, "README.md", "docs/intro.md")

      assert {:ok, "hello\n", _} = Workspace.read(ws, "docs/intro.md")
      assert {:error, :not_found} = Workspace.read(ws, "README.md")
    end

    test "missing source returns :not_found", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:error, :not_found} = Workspace.move(ws, "nope", "elsewhere")
    end

    test "refuses to move a directory in v1", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:error, :cannot_move_directory} = Workspace.move(ws, "src", "src2")
    end

    test "refuses to overwrite an existing directory", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:error, :eisdir} = Workspace.move(ws, "README.md", "src")
    end

    test "diff after move shows added + deleted", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.move(ws, "src/a.ex", "lib/a.ex")
      {:ok, changes, _} = Workspace.diff(ws)
      assert Enum.sort(changes) == [{:added, "lib/a.ex"}, {:deleted, "src/a.ex"}]
    end
  end

  describe "revert/2" do
    test "restores a modified file to base content", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "src/a.ex", "broken")
      {:ok, ws} = Workspace.revert(ws, "src/a.ex")
      assert {:ok, "module A\n", _} = Workspace.read(ws, "src/a.ex")
    end

    test "removes a file the agent added", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "added.txt", "agent's contribution")
      {:ok, ws} = Workspace.revert(ws, "added.txt")
      assert {:error, :not_found} = Workspace.read(ws, "added.txt")
    end

    test "no-op on pristine workspace", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      assert {:ok, ws_after} = Workspace.revert(ws, "anything")
      assert ws_after.head_tree == nil
    end

    test "revert leaves siblings untouched", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "src/a.ex", "broken-a")
      {:ok, ws} = Workspace.write(ws, "src/b.ex", "edited-b")

      {:ok, ws} = Workspace.revert(ws, "src/a.ex")

      assert {:ok, "module A\n", _} = Workspace.read(ws, "src/a.ex")
      assert {:ok, "edited-b", _} = Workspace.read(ws, "src/b.ex")
    end
  end

  describe "diff/2 with :content" do
    test "returns rich change entries with before/after blob bytes", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "src/a.ex", "rewritten\n")
      {:ok, ws} = Workspace.write(ws, "lib/new.ex", "new file\n")
      {:ok, ws} = Workspace.rm(ws, "README.md")

      {:ok, changes, _ws} = Workspace.diff(ws, content: true)
      changes_by_path = Map.new(changes, fn c -> {c.path, c} end)

      assert %{op: :modified, before: "module A\n", after: "rewritten\n"} =
               changes_by_path["src/a.ex"]

      assert %{op: :added, before: nil, after: "new file\n"} = changes_by_path["lib/new.ex"]

      assert %{op: :deleted, before: "hello\n", after: nil} = changes_by_path["README.md"]
    end
  end

  describe "diff/2 with :against" do
    test "compares against a snapshot rather than base_ref", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")

      {:ok, ws} = Workspace.write(ws, "step1.txt", "first")
      checkpoint = Workspace.snapshot(ws)

      {:ok, ws} = Workspace.write(ws, "step2.txt", "second")
      {:ok, ws} = Workspace.rm(ws, "README.md")

      {:ok, changes, _ws} = Workspace.diff(ws, against: checkpoint)
      changes = Enum.sort(changes)

      # step1.txt was already in the checkpoint — not in this diff.
      assert {:added, "step2.txt"} in changes
      assert {:deleted, "README.md"} in changes
      refute Enum.any?(changes, fn {_, p} -> p == "step1.txt" end)
    end

    test ":pristine is an alias for base_ref", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "x.txt", "x")

      {:ok, default, _} = Workspace.diff(ws)
      {:ok, against_pristine, _} = Workspace.diff(ws, against: :pristine)

      assert default == against_pristine
    end
  end

  describe "merge/3" do
    test "non-overlapping changes from a sibling workspace merge cleanly", %{repo: repo} do
      ws_base = Workspace.open(repo, "refs/heads/main")

      ws_a = ws_base
      ws_b = ws_base

      {:ok, ws_a} = Workspace.write(ws_a, "src/a.ex", "ours-a")
      {:ok, ws_b} = Workspace.write(ws_b, "src/b.ex", "theirs-b")

      assert {:ok, ws_merged} = Workspace.merge(ws_a, ws_b)

      assert {:ok, "ours-a", _} = Workspace.read(ws_merged, "src/a.ex")
      assert {:ok, "theirs-b", _} = Workspace.read(ws_merged, "src/b.ex")
    end

    test "conflicting writes return :conflict with workspace unchanged", %{repo: repo} do
      ws_base = Workspace.open(repo, "refs/heads/main")
      ws_a = ws_base
      ws_b = ws_base

      {:ok, ws_a} = Workspace.write(ws_a, "src/a.ex", "ours")
      {:ok, ws_b} = Workspace.write(ws_b, "src/a.ex", "theirs")

      head_before = ws_a.head_tree

      assert {:conflict, [{:both_modified, "src/a.ex"}], ws_after} =
               Workspace.merge(ws_a, ws_b)

      # workspace head_tree unchanged
      assert ws_after.head_tree == head_before
    end

    test ":ours strategy resolves conflicts to our side", %{repo: repo} do
      ws_base = Workspace.open(repo, "refs/heads/main")
      ws_a = ws_base
      ws_b = ws_base

      {:ok, ws_a} = Workspace.write(ws_a, "src/a.ex", "ours-version")
      {:ok, ws_b} = Workspace.write(ws_b, "src/a.ex", "theirs-version")

      assert {:ok, ws_merged} = Workspace.merge(ws_a, ws_b, strategy: :ours)

      assert {:ok, "ours-version", _} = Workspace.read(ws_merged, "src/a.ex")
    end

    test ":theirs strategy resolves conflicts to their side", %{repo: repo} do
      ws_base = Workspace.open(repo, "refs/heads/main")
      ws_a = ws_base
      ws_b = ws_base

      {:ok, ws_a} = Workspace.write(ws_a, "src/a.ex", "ours-version")
      {:ok, ws_b} = Workspace.write(ws_b, "src/a.ex", "theirs-version")

      assert {:ok, ws_merged} = Workspace.merge(ws_a, ws_b, strategy: :theirs)

      assert {:ok, "theirs-version", _} = Workspace.read(ws_merged, "src/a.ex")
    end

    test "merging :pristine is a no-op", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "x.txt", "x")
      assert {:ok, ws_after} = Workspace.merge(ws, :pristine)
      assert ws_after.head_tree == ws.head_tree
    end

    test "merge into pristine workspace from a divergent workspace", %{repo: repo} do
      ws_base = Workspace.open(repo, "refs/heads/main")
      ws_other = ws_base
      {:ok, ws_other} = Workspace.write(ws_other, "lib/extra.ex", "extra")

      assert {:ok, ws_merged} = Workspace.merge(ws_base, ws_other)
      assert {:ok, "extra", _} = Workspace.read(ws_merged, "lib/extra.ex")
    end

    test "merging a same-repo tree-sha works without import", %{repo: repo} do
      # When source is a tree-sha already in target's repo, merge by SHA
      # is the optimized path (no object copying needed). Re-open from
      # the post-write repo so the tree exists in target's store.
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, ws} = Workspace.write(ws, "src/c.ex", "merged-c")
      tree = Workspace.snapshot(ws)

      ws_fresh = Workspace.open(ws.repo, "refs/heads/main")
      assert {:ok, ws_merged} = Workspace.merge(ws_fresh, tree)
      assert {:ok, "merged-c", _} = Workspace.read(ws_merged, "src/c.ex")
    end
  end

  describe "materialized_walk/1" do
    test "returns a stream and a materialized workspace", %{repo: repo} do
      ws = Workspace.open(repo, "refs/heads/main")
      {:ok, stream, ws_eager} = Workspace.materialized_walk(ws)

      paths = stream |> Enum.map(fn {p, _sha} -> p end) |> Enum.sort()
      assert "README.md" in paths
      assert "src/a.ex" in paths

      # repo flipped to :eager (no-op on already-eager, still :eager)
      assert ws_eager.repo.mode == :eager
    end
  end
end
