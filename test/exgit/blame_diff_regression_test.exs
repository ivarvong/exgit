defmodule Exgit.BlameDiffRegressionTest do
  # Regression fixture for diff-algorithm tie-breaking. The other blame
  # tests use scenarios where the LCS is unambiguous (one valid match
  # set), so they pass for any optimal diff algorithm. This module pins
  # attribution for cases where Myers and a naive LCS DP could pick
  # different valid matches — adjacent duplicates with insertions and
  # transpositions. If the Myers tie-break ever shifts, blame results
  # for these inputs will change, and these tests will catch it.
  use ExUnit.Case, async: true

  alias Exgit.Blame
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore}

  defp build_repo(commit_specs) do
    {store, ref_store, shas} =
      Enum.reduce(commit_specs, {ObjectStore.Memory.new(), RefStore.Memory.new(), %{}}, fn
        {label, contents, parents, author, ts}, {store, rs, shas} ->
          {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new(contents))
          tree = Tree.new([{"100644", "f.txt", blob_sha}])
          {:ok, tree_sha, store} = ObjectStore.put(store, tree)
          parent_shas = Enum.map(parents, &Map.fetch!(shas, &1))

          commit =
            Commit.new(
              tree: tree_sha,
              parents: parent_shas,
              author: "#{author} <#{author}@example.com> #{ts} +0000",
              committer: "#{author} <#{author}@example.com> #{ts} +0000",
              message: "#{label}\n"
            )

          {:ok, commit_sha, store} = ObjectStore.put(store, commit)
          {store, rs, Map.put(shas, label, commit_sha)}
      end)

    head_sha = Map.fetch!(shas, List.last(Enum.map(commit_specs, &elem(&1, 0))))
    {:ok, rs} = RefStore.write(ref_store, "refs/heads/main", head_sha, [])
    {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = %Exgit.Repository{
      object_store: store,
      ref_store: rs,
      config: Exgit.Config.new(),
      path: nil
    }

    {repo, shas}
  end

  describe "adjacent identical lines" do
    # c1 introduces [L1, X, L2]. c2 inserts a second X adjacent to the
    # first: [L1, X, X, L2]. At HEAD, two X lines are present; one came
    # from c1, the other from c2. Myers must consistently pick which is
    # which. This test pins the choice.
    test "duplicate insertion attributes the new line to the inserting commit" do
      {repo, shas} =
        build_repo([
          {:c1, "L1\nX\nL2\n", [], "alice", 1_700_000_001},
          {:c2, "L1\nX\nX\nL2\n", [:c1], "bob", 1_700_000_002}
        ])

      assert {:ok, entries, _} = Blame.blame(repo, "HEAD", "f.txt")
      assert length(entries) == 4

      [e1, e2, e3, e4] = entries

      # L1 and L2 are unambiguous — both from c1.
      assert e1.line == "L1"
      assert e1.commit_sha == shas.c1
      assert e4.line == "L2"
      assert e4.commit_sha == shas.c1

      # The two adjacent X lines: exactly one must be attributed to c1
      # (the original) and the other to c2 (the insertion). Either
      # ordering is a valid LCS — but the choice must be CONSISTENT.
      x_attribs = Enum.sort([e2.commit_sha, e3.commit_sha])

      assert x_attribs == Enum.sort([shas.c1, shas.c2]),
             "expected one X from c1 and one from c2, got #{inspect(x_attribs)}"

      # Pin the specific tie-break: Myers' greedy snake extension
      # matches a[1]=X to b[1]=X first, leaving b[2] as the new line.
      # So the FIRST X (line 2) is from c1, the SECOND X (line 3) is
      # from c2. If this assertion flips, the diff tie-break has
      # changed.
      assert e2.commit_sha == shas.c1, "expected line 2 (first X) from c1"
      assert e3.commit_sha == shas.c2, "expected line 3 (second X) from c2"
    end

    # Three-commit version: c1 makes [A, X, B], c2 inserts a second X to
    # produce [A, X, X, B], c3 inserts Y at the front: [Y, A, X, X, B].
    # The two X's must remain attributed correctly through one more
    # commit of context shifting.
    test "duplicate persists correctly through subsequent unrelated insertion" do
      {repo, shas} =
        build_repo([
          {:c1, "A\nX\nB\n", [], "alice", 1_700_000_001},
          {:c2, "A\nX\nX\nB\n", [:c1], "bob", 1_700_000_002},
          {:c3, "Y\nA\nX\nX\nB\n", [:c2], "carol", 1_700_000_003}
        ])

      assert {:ok, entries, _} = Blame.blame(repo, "HEAD", "f.txt")
      assert length(entries) == 5

      [e1, e2, e3, e4, e5] = entries

      assert e1.line == "Y"
      assert e1.commit_sha == shas.c3
      assert e2.line == "A"
      assert e2.commit_sha == shas.c1
      assert e5.line == "B"
      assert e5.commit_sha == shas.c1

      # First X stays attributed to c1, second X to c2 — same tie-break
      # as the previous test, propagated through c3.
      assert e3.line == "X"
      assert e3.commit_sha == shas.c1
      assert e4.line == "X"
      assert e4.commit_sha == shas.c2
    end
  end

  describe "transposition" do
    # c1: [A, B, C]. c2 swaps A and B: [B, A, C]. LCS length is 2 — two
    # valid choices: keep {A, C} (lose B) or keep {B, C} (lose A). The
    # losing line gets re-attributed to c2.
    test "swap of adjacent lines attributes one line to the swap commit" do
      {repo, shas} =
        build_repo([
          {:c1, "A\nB\nC\n", [], "alice", 1_700_000_001},
          {:c2, "B\nA\nC\n", [:c1], "bob", 1_700_000_002}
        ])

      assert {:ok, entries, _} = Blame.blame(repo, "HEAD", "f.txt")
      assert length(entries) == 3
      [e1, e2, e3] = entries

      # C is unambiguous.
      assert e3.line == "C"
      assert e3.commit_sha == shas.c1

      # Of {B, A} at lines 1 and 2, exactly one is attributed to c1
      # (the survivor in the LCS) and the other to c2 (the line that
      # moved across the boundary). Pin Myers' specific choice.
      assert e1.line == "B"
      assert e2.line == "A"

      # Myers on a=[A,B,C], b=[B,A,C] with the codebase's tie-break
      # picks LCS {B, C}. So B at line 1 is preserved (from c1) and
      # A at line 2 is the line that moved across the swap (from c2).
      # If this flips, the diff tie-break has changed.
      attributions = {e1.commit_sha, e2.commit_sha}

      assert attributions == {shas.c1, shas.c2},
             "expected {c1, c2} (B preserved, A re-attributed); got #{inspect(attributions)}"
    end
  end

  describe "split insertions" do
    # c1: [A, B]. c2 inserts X both before and after B: [A, X, B, X].
    # LCS is unambiguously {A, B}. Both X's are new. No tie-breaking
    # involved — but it confirms multi-position insertion works.
    test "insertions on both sides of a preserved line" do
      {repo, shas} =
        build_repo([
          {:c1, "A\nB\n", [], "alice", 1_700_000_001},
          {:c2, "A\nX\nB\nX\n", [:c1], "bob", 1_700_000_002}
        ])

      assert {:ok, entries, _} = Blame.blame(repo, "HEAD", "f.txt")
      [e1, e2, e3, e4] = entries

      assert e1.line == "A"
      assert e1.commit_sha == shas.c1
      assert e2.line == "X"
      assert e2.commit_sha == shas.c2
      assert e3.line == "B"
      assert e3.commit_sha == shas.c1
      assert e4.line == "X"
      assert e4.commit_sha == shas.c2
    end
  end
end
