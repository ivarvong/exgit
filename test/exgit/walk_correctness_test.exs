defmodule Exgit.WalkCorrectnessTest do
  use ExUnit.Case, async: true

  alias Exgit.Test.CommitGraph
  alias Exgit.Walk

  describe "topo order (P0.14)" do
    test "Kahn invariant: no commit appears before any of its descendants" do
      # Graph (arrows = parent edges, so G <- A <- B means A is a parent of B):
      #
      #   A - B - D - F
      #    \         /
      #     C ----- E
      #
      # Here F is a merge of D and E. Topo order must yield F first; D and E
      # in some order; then B, C; then A. What must NOT happen: an ancestor
      # showing up before one of its descendants.
      graph = %{
        "A" => [],
        "B" => ["A"],
        "C" => ["A"],
        "D" => ["B"],
        "E" => ["C"],
        "F" => ["D", "E"]
      }

      {repo, shas} = CommitGraph.build(graph)

      walked =
        Walk.ancestors(repo, shas["F"], order: :topo)
        |> Enum.map(&Exgit.Object.Commit.sha(&1))

      # Convert SHAs back to names for readable assertions.
      names = Enum.map(walked, &CommitGraph.name_of(shas, &1))

      # Kahn invariant: position(child) < position(parent) for every edge.
      positions = Map.new(Enum.with_index(names))

      for {child, parents} <- graph, parent <- parents do
        pc = Map.fetch!(positions, child)
        pp = Map.fetch!(positions, parent)

        assert pc < pp,
               "Kahn invariant violated: parent #{parent} (pos #{pp}) came before child #{child} (pos #{pc}). Walk: #{inspect(names)}"
      end

      # All commits must be present.
      assert Enum.sort(names) == Enum.sort(Map.keys(graph))
    end

    test "linear history emits newest to oldest" do
      graph = %{
        "A" => [],
        "B" => ["A"],
        "C" => ["B"],
        "D" => ["C"]
      }

      {repo, shas} = CommitGraph.build(graph)

      names =
        Walk.ancestors(repo, shas["D"], order: :topo)
        |> Enum.map(&Exgit.Object.Commit.sha(&1))
        |> Enum.map(&CommitGraph.name_of(shas, &1))

      assert names == ["D", "C", "B", "A"]
    end

    test "octopus merge: four parents don't interleave with a long chain" do
      # H has parents P1..P4; P1 has a long chain back to a common root.
      # If topo is really Kahn, H is first, then siblings drain before we
      # pop the chain.
      graph = %{
        "R" => [],
        "C1" => ["R"],
        "C2" => ["C1"],
        "C3" => ["C2"],
        "P1" => ["C3"],
        "P2" => ["R"],
        "P3" => ["R"],
        "P4" => ["R"],
        "H" => ["P1", "P2", "P3", "P4"]
      }

      {repo, shas} = CommitGraph.build(graph)

      names =
        Walk.ancestors(repo, shas["H"], order: :topo)
        |> Enum.map(&Exgit.Object.Commit.sha(&1))
        |> Enum.map(&CommitGraph.name_of(shas, &1))

      positions = Map.new(Enum.with_index(names))

      for {child, parents} <- graph, parent <- parents do
        assert positions[child] < positions[parent],
               "Kahn invariant violated: #{parent} came before #{child}: #{inspect(names)}"
      end
    end
  end

  describe "date order" do
    test "orders by committer timestamp, newest first" do
      graph = %{
        "A" => [],
        "B" => ["A"],
        "C" => ["A"]
      }

      # Make B older than C so date order yields C, B, A regardless of which
      # was visited first via topological expansion.
      # We extend the graph with a merge commit M that has both B and C as
      # parents so the walk visits both branches.
      graph2 = Map.put(graph, "M", ["B", "C"])

      {repo, shas} =
        CommitGraph.build(graph2,
          timestamps: %{"A" => 1000, "B" => 2000, "C" => 3000, "M" => 4000}
        )

      names =
        Walk.ancestors(repo, shas["M"], order: :date)
        |> Enum.map(&Exgit.Object.Commit.sha(&1))
        |> Enum.map(&CommitGraph.name_of(shas, &1))

      # Date order: newest first → M (4000), C (3000), B (2000), A (1000).
      assert names == ["M", "C", "B", "A"]
    end
  end
end
