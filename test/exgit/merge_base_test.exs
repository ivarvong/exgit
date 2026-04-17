defmodule Exgit.MergeBaseTest do
  use ExUnit.Case, async: true

  alias Exgit.Walk
  alias Exgit.Test.CommitGraph

  describe "merge_base correctness (P0.15)" do
    test "simple fork-and-merge: returns the fork point" do
      # Graph:
      #        B
      #       /
      #   R--A
      #       \
      #        C
      #
      # merge_base(B, C) must be A.
      graph = %{
        "R" => [],
        "A" => ["R"],
        "B" => ["A"],
        "C" => ["A"]
      }

      {repo, shas} = CommitGraph.build(graph)

      assert {:ok, sha} = Walk.merge_base(repo, [shas["B"], shas["C"]])
      assert sha == shas["A"]
    end

    test "criss-cross merge: picks a genuine merge base (topology, not timestamp)" do
      # Classic criss-cross:
      #
      #      A --- B -- M1
      #       \ /        \
      #        X          D
      #       / \        /
      #      C --- D -- M2
      #
      # Actually the textbook criss-cross:
      #
      #            B --\
      #           /     \
      #      R-- A       M1
      #           \     /
      #            C --/
      #           / \
      #      R-- A   M2
      #           \ /
      #            B ...
      #
      # Simpler: two merge commits M1, M2 each combining B and C.
      # merge_base(M1, M2) must be one of {B, C} — both are valid LCAs.
      # The buggy timestamp-picking code might return A (older) if B and C
      # have inconvenient timestamps.
      graph = %{
        "R" => [],
        "A" => ["R"],
        "B" => ["A"],
        "C" => ["A"],
        "M1" => ["B", "C"],
        "M2" => ["C", "B"]
      }

      # Set timestamps so that A is WAY newer than B and C — if impl picks
      # by timestamp alone it would (wrongly) pick A.
      timestamps = %{
        "R" => 1_000,
        "A" => 5_000,
        "B" => 2_000,
        "C" => 3_000,
        "M1" => 6_000,
        "M2" => 6_000
      }

      {repo, shas} = CommitGraph.build(graph, timestamps: timestamps)

      assert {:ok, base} = Walk.merge_base(repo, [shas["M1"], shas["M2"]])

      assert base in [shas["B"], shas["C"]],
             "expected B or C, got #{CommitGraph.name_of(shas, base)}"
    end

    test "with skewed timestamps, picks topology not timestamp" do
      # Linear chain: R <- A <- B <- C. merge_base(C, B) must be B.
      # If we set B's timestamp BEFORE R's, a timestamp-based impl might
      # pick R instead.
      graph = %{
        "R" => [],
        "A" => ["R"],
        "B" => ["A"],
        "C" => ["B"]
      }

      # B has the oldest timestamp despite being newest topologically.
      timestamps = %{
        "R" => 5_000,
        "A" => 4_000,
        "B" => 1_000,
        "C" => 6_000
      }

      {repo, shas} = CommitGraph.build(graph, timestamps: timestamps)

      assert {:ok, base} = Walk.merge_base(repo, [shas["C"], shas["B"]])

      assert base == shas["B"],
             "expected B (topology ancestor), got #{CommitGraph.name_of(shas, base)}"
    end

    test "disjoint graphs return :none" do
      # Build two separate histories. Use two separate build calls and
      # merge the object stores.
      graph_a = %{"A1" => [], "A2" => ["A1"]}
      graph_b = %{"B1" => [], "B2" => ["B1"]}

      {repo_a, shas_a} = CommitGraph.build(graph_a)
      {repo_b, shas_b} = CommitGraph.build(graph_b)

      # Merge the two object stores.
      %Exgit.ObjectStore.Memory{objects: oa} = repo_a.object_store
      %Exgit.ObjectStore.Memory{objects: ob} = repo_b.object_store
      merged = %Exgit.ObjectStore.Memory{objects: Map.merge(oa, ob)}
      repo = %{object_store: merged}

      assert {:error, :none} = Walk.merge_base(repo, [shas_a["A2"], shas_b["B2"]])
    end

    test "does not materialize full ancestor sets (perf smoke test)" do
      # Long linear chain of 1000 commits with a single fork near the tip.
      n = 500

      chain =
        for i <- 0..(n - 1), into: %{} do
          parent = if i == 0, do: [], else: ["n#{i - 1}"]
          {"n#{i}", parent}
        end

      tip = "n#{n - 1}"

      graph =
        chain
        |> Map.put("fork_a", [tip])
        |> Map.put("fork_b", [tip])

      {repo, shas} = CommitGraph.build(graph)

      # merge_base should not hit the root for a tip-level fork — the
      # frontier algorithm should identify `tip` as the LCA within a few
      # commits.
      {time_us, {:ok, base}} =
        :timer.tc(fn -> Walk.merge_base(repo, [shas["fork_a"], shas["fork_b"]]) end)

      assert base == shas[tip]
      # Linear ancestors-set would walk 500 commits twice + set ops. A
      # proper frontier BFS should find the LCA within a handful of
      # iterations regardless of chain length. Generous headroom for
      # shared CI runners.
      assert time_us < 500_000, "merge_base took #{time_us}us — likely walking full chain"
    end
  end
end
