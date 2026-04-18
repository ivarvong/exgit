defmodule Exgit.WalkMergeBasePerfTest do
  @moduledoc """
  Regression for review finding #25 (`all_stale?` O(Q²)).

  The fix maintains `stale_in_queue` incrementally rather than
  scanning the whole gb_set per iteration. Correctness is covered
  by `Exgit.MergeBaseTest`; this file covers the stale-counter
  bookkeeping by running merge_base on a synthetic history with
  hundreds of shared ancestors and asserting (a) correctness and
  (b) a soft performance floor.
  """

  use ExUnit.Case, async: true

  alias Exgit.{Object.Commit, ObjectStore, Walk}
  alias Exgit.ObjectStore.Memory

  # Build a linear history with `depth` commits, then two divergent
  # tips sharing the full prefix. merge_base(tip_a, tip_b) must find
  # the shared commit at depth-1. The reviewer's concern was that
  # the all_stale? scan over the frontier queue made this O(Q^2);
  # we verify by comparing the wall time against a budget that
  # would comfortably fail a quadratic impl.
  test "merge_base on histories with many shared ancestors is not O(Q^2)" do
    depth = 500

    {shared_tip, store} = build_chain(Memory.new(), depth, nil, "shared")

    # Two more commits, each branching off `shared_tip`. Tag them
    # with distinct message prefixes so the commit SHAs diverge.
    {tip_a, store} = build_chain(store, 5, shared_tip, "a")
    {tip_b, store} = build_chain(store, 5, shared_tip, "b")

    repo = %{object_store: store}

    {micros, {:ok, base}} =
      :timer.tc(fn -> Walk.merge_base(repo, [tip_a, tip_b]) end)

    assert base == shared_tip
    # Soft budget: 500ms for 500-deep shared history. With the O(Q²)
    # bug and depth=500 this ran into multi-second territory on
    # macos/linux.
    assert micros < 500_000,
           "merge_base took #{micros}µs for depth=#{depth}; expected <500_000µs"
  end

  defp build_chain(store, 0, parent, _tag), do: {parent, store}

  defp build_chain(store, n, parent, tag) do
    parents = if parent, do: [parent], else: []

    # Use the 0-index as the commit's timestamp so each commit has a
    # distinct author time — the merge_base frontier ordering depends
    # on timestamps.
    c =
      Commit.new(
        tree: :binary.copy(<<0>>, 20),
        parents: parents,
        author: "Author <a@a.com> #{n} +0000",
        committer: "Author <a@a.com> #{n} +0000",
        message: "#{tag} commit #{n}\n"
      )

    {:ok, sha, store} = ObjectStore.put(store, c)
    build_chain(store, n - 1, sha, tag)
  end
end
