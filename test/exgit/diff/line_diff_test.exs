defmodule Exgit.Diff.LineDiffTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.Diff.LineDiff

  describe "matched_pairs/2 — base cases" do
    test "empty a" do
      assert LineDiff.matched_pairs([], ["x"]) == []
    end

    test "empty b" do
      assert LineDiff.matched_pairs(["x"], []) == []
    end

    test "both empty" do
      assert LineDiff.matched_pairs([], []) == []
    end

    test "identical single-line input" do
      assert LineDiff.matched_pairs(["a"], ["a"]) == [{0, 0}]
    end

    test "disjoint single-line input" do
      assert LineDiff.matched_pairs(["a"], ["b"]) == []
    end
  end

  describe "matched_pairs/2 — identity" do
    test "identical multi-line" do
      a = ["a", "b", "c", "d"]
      assert LineDiff.matched_pairs(a, a) == [{0, 0}, {1, 1}, {2, 2}, {3, 3}]
    end
  end

  describe "matched_pairs/2 — insertion / deletion" do
    test "line inserted in middle" do
      assert LineDiff.matched_pairs(
               ["a", "c"],
               ["a", "b", "c"]
             ) == [{0, 0}, {1, 2}]
    end

    test "line deleted from middle" do
      assert LineDiff.matched_pairs(
               ["a", "b", "c"],
               ["a", "c"]
             ) == [{0, 0}, {2, 1}]
    end

    test "line modified (delete + insert)" do
      # a=[a,b,c], b=[a,X,c]: a[0]=a=b[0], a[2]=c=b[2]. b[1]=X is new.
      assert LineDiff.matched_pairs(
               ["a", "b", "c"],
               ["a", "X", "c"]
             ) == [{0, 0}, {2, 2}]
    end

    test "entirely new content (no common lines)" do
      assert LineDiff.matched_pairs(["a", "b"], ["c", "d"]) == []
    end

    test "leading and trailing context with middle changes" do
      a = ["l1", "l2", "X", "Y", "l3", "l4"]
      b = ["l1", "l2", "A", "B", "C", "l3", "l4"]

      # l1, l2, l3, l4 all persist; X and Y go; A, B, C are new.
      assert LineDiff.matched_pairs(a, b) == [{0, 0}, {1, 1}, {4, 5}, {5, 6}]
    end
  end

  describe "matched_pairs/2 — transposition / duplicates" do
    test "single duplicated line in both" do
      assert LineDiff.matched_pairs(["x", "x"], ["x", "x"]) == [{0, 0}, {1, 1}]
    end

    test "transposition is handled sensibly" do
      # a=[a,b], b=[b,a]: LCS length 1 — either {0,1} (keep 'a') or
      # {1,0} (keep 'b'). The implementation is deterministic; we
      # just assert the length and that the indices are legal.
      pairs = LineDiff.matched_pairs(["a", "b"], ["b", "a"])
      assert length(pairs) == 1

      for {ai, bi} <- pairs do
        assert ai in [0, 1]
        assert bi in [0, 1]
      end
    end
  end

  describe "b_additions/2 + b_carryovers/1" do
    test "all new when LCS is empty" do
      pairs = LineDiff.matched_pairs(["x"], ["a", "b"])
      assert LineDiff.b_additions(pairs, 2) == [0, 1]
      assert LineDiff.b_carryovers(pairs) == []
    end

    test "all carried when inputs identical" do
      pairs = LineDiff.matched_pairs(["a", "b"], ["a", "b"])
      assert LineDiff.b_additions(pairs, 2) == []
      assert Enum.sort(LineDiff.b_carryovers(pairs)) == [{0, 0}, {1, 1}]
    end

    test "mixed additions and carryovers" do
      pairs =
        LineDiff.matched_pairs(
          ["unchanged1", "unchanged2"],
          ["unchanged1", "NEW", "unchanged2", "NEW2"]
        )

      assert LineDiff.b_additions(pairs, 4) == [1, 3]
      # b indices 0 and 2 are carried from a.
      assert Enum.sort(LineDiff.b_carryovers(pairs)) == [{0, 0}, {2, 1}]
    end
  end

  describe "property: LCS length invariants" do
    property "matched_pairs length is bounded by min(|a|, |b|)" do
      check all(
              a <- StreamData.list_of(line(), max_length: 20),
              b <- StreamData.list_of(line(), max_length: 20),
              max_runs: 200
            ) do
        pairs = LineDiff.matched_pairs(a, b)
        assert length(pairs) <= min(length(a), length(b))
      end
    end

    property "matched pairs are strictly increasing in both indices" do
      check all(
              a <- StreamData.list_of(line(), max_length: 15),
              b <- StreamData.list_of(line(), max_length: 15),
              max_runs: 200
            ) do
        pairs = LineDiff.matched_pairs(a, b)

        a_idxs = Enum.map(pairs, &elem(&1, 0))
        b_idxs = Enum.map(pairs, &elem(&1, 1))

        assert a_idxs == Enum.sort(a_idxs)
        assert b_idxs == Enum.sort(b_idxs)
        assert length(a_idxs) == length(Enum.uniq(a_idxs))
        assert length(b_idxs) == length(Enum.uniq(b_idxs))
      end
    end

    property "every matched pair refers to equal lines" do
      check all(
              a <- StreamData.list_of(line(), max_length: 15),
              b <- StreamData.list_of(line(), max_length: 15),
              max_runs: 200
            ) do
        pairs = LineDiff.matched_pairs(a, b)
        a_t = List.to_tuple(a)
        b_t = List.to_tuple(b)

        for {ai, bi} <- pairs do
          assert elem(a_t, ai) == elem(b_t, bi)
        end
      end
    end

    property "identity: matched_pairs(x, x) covers every line" do
      check all(
              a <- StreamData.list_of(line(), min_length: 1, max_length: 15),
              max_runs: 100
            ) do
        pairs = LineDiff.matched_pairs(a, a)
        expected = for i <- 0..(length(a) - 1), do: {i, i}
        assert pairs == expected
      end
    end

    defp line do
      # Small alphabet ensures collisions so LCS actually does work.
      StreamData.one_of(
        Enum.map(["a", "b", "c", "d", "e"], &StreamData.constant/1)
      )
    end
  end
end
