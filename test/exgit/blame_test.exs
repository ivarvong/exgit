defmodule Exgit.BlameTest do
  use ExUnit.Case, async: true

  alias Exgit.Blame
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore}

  # Build a linear history: commit 1 creates a file with lines
  # [L1, L2, L3]; commit 2 adds L4; commit 3 replaces L2 with X2.
  # Final file at HEAD: [L1, X2, L3, L4].
  # Attribution:
  #   L1 → c1
  #   X2 → c3  (the modification that introduced X2)
  #   L3 → c1
  #   L4 → c2
  setup do
    store = ObjectStore.Memory.new()

    # --- commit 1: create f.txt with three lines ---
    {:ok, b1_sha, store} = ObjectStore.put(store, Blob.new("L1\nL2\nL3\n"))
    t1 = Tree.new([{"100644", "f.txt", b1_sha}])
    {:ok, t1_sha, store} = ObjectStore.put(store, t1)

    c1 =
      Commit.new(
        tree: t1_sha,
        parents: [],
        author: "Alice <alice@example.com> 1700000001 +0000",
        committer: "Alice <alice@example.com> 1700000001 +0000",
        message: "one\n"
      )

    {:ok, c1_sha, store} = ObjectStore.put(store, c1)

    # --- commit 2: append L4 ---
    {:ok, b2_sha, store} = ObjectStore.put(store, Blob.new("L1\nL2\nL3\nL4\n"))
    t2 = Tree.new([{"100644", "f.txt", b2_sha}])
    {:ok, t2_sha, store} = ObjectStore.put(store, t2)

    c2 =
      Commit.new(
        tree: t2_sha,
        parents: [c1_sha],
        author: "Bob <bob@example.com> 1700000002 +0000",
        committer: "Bob <bob@example.com> 1700000002 +0000",
        message: "add L4\n"
      )

    {:ok, c2_sha, store} = ObjectStore.put(store, c2)

    # --- commit 3: replace L2 with X2 ---
    {:ok, b3_sha, store} = ObjectStore.put(store, Blob.new("L1\nX2\nL3\nL4\n"))
    t3 = Tree.new([{"100644", "f.txt", b3_sha}])
    {:ok, t3_sha, store} = ObjectStore.put(store, t3)

    c3 =
      Commit.new(
        tree: t3_sha,
        parents: [c2_sha],
        author: "Carol <carol@example.com> 1700000003 +0000",
        committer: "Carol <carol@example.com> 1700000003 +0000",
        message: "replace L2 with X2\n"
      )

    {:ok, c3_sha, store} = ObjectStore.put(store, c3)

    {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", c3_sha, [])
    {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = %Exgit.Repository{
      object_store: store,
      ref_store: rs,
      config: Exgit.Config.new(),
      path: nil
    }

    {:ok, repo: repo, shas: %{c1: c1_sha, c2: c2_sha, c3: c3_sha}}
  end

  test "attributes each line in linear history", %{repo: repo, shas: shas} do
    assert {:ok, entries, _} = Blame.blame(repo, "HEAD", "f.txt")
    assert length(entries) == 4

    [e1, e2, e3, e4] = entries

    # L1 was introduced by c1, never touched.
    assert e1.line_number == 1
    assert e1.line == "L1"
    assert e1.commit_sha == shas.c1
    assert e1.author_name == "Alice"

    # X2 was introduced by c3 (replaced L2).
    assert e2.line_number == 2
    assert e2.line == "X2"
    assert e2.commit_sha == shas.c3
    assert e2.author_name == "Carol"

    # L3 was introduced by c1, survived c2 and c3.
    assert e3.line == "L3"
    assert e3.commit_sha == shas.c1

    # L4 was introduced by c2.
    assert e4.line == "L4"
    assert e4.commit_sha == shas.c2
    assert e4.author_name == "Bob"
  end

  test "single-commit file: all lines attributed to that commit", %{repo: repo, shas: shas} do
    # Use c1 directly as ref.
    assert {:ok, entries, _} = Blame.blame(repo, shas.c1, "f.txt")
    assert length(entries) == 3
    assert Enum.all?(entries, &(&1.commit_sha == shas.c1))
    assert Enum.all?(entries, &(&1.author_name == "Alice"))
  end

  test "empty file blame returns empty list", %{repo: repo} do
    store = repo.object_store

    {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new(""))
    t = Tree.new([{"100644", "empty.txt", blob_sha}])
    {:ok, t_sha, store} = ObjectStore.put(store, t)

    c =
      Commit.new(
        tree: t_sha,
        parents: [],
        author: "Z <z@z> 1700000000 +0000",
        committer: "Z <z@z> 1700000000 +0000",
        message: "e\n"
      )

    {:ok, c_sha, store} = ObjectStore.put(store, c)
    repo = %{repo | object_store: store}

    assert {:ok, [], _} = Blame.blame(repo, c_sha, "empty.txt")
  end

  test "missing path returns :not_found", %{repo: repo} do
    assert {:error, :not_found} = Blame.blame(repo, "HEAD", "nope.txt")
  end

  test "author metadata correctly parsed", %{repo: repo, shas: shas} do
    {:ok, [e1 | _], _} = Blame.blame(repo, "HEAD", "f.txt")

    assert e1.author_email == "alice@example.com"
    assert e1.author_time == 1_700_000_001
    assert e1.summary == "one"

    _ = shas
  end

  test "accepts raw commit SHA as reference", %{repo: repo, shas: shas} do
    assert {:ok, entries, _} = Blame.blame(repo, shas.c2, "f.txt")
    # At c2, file is [L1, L2, L3, L4]. Attribution:
    # L1, L2, L3 → c1; L4 → c2.
    [e1, e2, e3, e4] = entries
    assert e1.commit_sha == shas.c1
    assert e2.commit_sha == shas.c1
    assert e3.commit_sha == shas.c1
    assert e4.commit_sha == shas.c2
  end

  test "line deletion: survivors still correctly attributed", %{repo: repo, shas: shas} do
    # Build commit 4 on top of c3: delete X2 (middle line).
    # Final: [L1, L3, L4]. Attribution:
    #   L1 → c1, L3 → c1, L4 → c2.
    # No line should be attributed to c4 (which only deleted).
    store = repo.object_store

    {:ok, b4_sha, store} = ObjectStore.put(store, Blob.new("L1\nL3\nL4\n"))
    t4 = Tree.new([{"100644", "f.txt", b4_sha}])
    {:ok, t4_sha, store} = ObjectStore.put(store, t4)

    c4 =
      Commit.new(
        tree: t4_sha,
        parents: [shas.c3],
        author: "Dan <dan@example.com> 1700000004 +0000",
        committer: "Dan <dan@example.com> 1700000004 +0000",
        message: "delete X2\n"
      )

    {:ok, c4_sha, store} = ObjectStore.put(store, c4)
    repo = %{repo | object_store: store}

    assert {:ok, entries, _} = Blame.blame(repo, c4_sha, "f.txt")
    assert length(entries) == 3

    [e1, e2, e3] = entries
    assert e1.commit_sha == shas.c1
    assert e2.commit_sha == shas.c1
    assert e3.commit_sha == shas.c2
  end
end
