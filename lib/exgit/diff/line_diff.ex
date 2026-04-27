defmodule Exgit.Diff.LineDiff do
  @moduledoc """
  Line-level diff between two sequences of lines via Myers diff.

  The primary output is a list of **matched pairs** `[{a_idx, b_idx}]`
  — 0-based indices of lines that appear in both inputs in the same
  relative order. Anything in `a` not in that set is "deleted";
  anything in `b` not in that set is "added."

  ## Algorithm: Myers diff

  Myers (1986) finds the *shortest edit script* (SES) — the minimum
  number of insertions and deletions that transforms `a` into `b`.
  An SES corresponds to the *longest common subsequence* (LCS).

  ### Complexity

  * Time:  O((N + M) × D)  where D = |insertions| + |deletions|
  * Space: O((N + M) × D)  for the backtracking trace

  For typical blame workloads where each commit edits a handful of
  lines (small D), this is **orders of magnitude faster** than the
  previous O(N × M) LCS DP:

  | File size | LCS DP (D≈10) | Myers (D≈10) |
  |-----------|---------------|-------------|
  | 100 lines | ~100K         | ~2K         |
  | 500 lines | ~2.5M         | ~10K        |
  | 5000 lines| ~250M         | ~100K       |

  ### The algorithm in brief

  A *diagonal* k = x − y represents all positions (x, y) where we've
  consumed x lines from A and y lines from B. Walking diagonally
  (x++, y++ while A[x]==B[y]) is a *snake* — free matching. A single
  horizontal step (x++) is a deletion; a vertical step (y++) is an
  insertion; together they cost one edit.

  **Forward phase:** for edit depth D = 0, 1, 2, …, explore every
  diagonal k ∈ {−D, −D+2, …, D−2, D}. On each diagonal, choose the
  greedy starting position (either V[k−1]+1 from the right or V[k+1]
  from below), extend the snake as far as possible, and record the
  furthest x. Save a snapshot of V at each D. Stop when some diagonal
  reaches (n, m).

  **Backtrack phase:** replay the snapshots in reverse, mirroring the
  forward greedy choice exactly. At each level, locate the snake
  (diagonal run of matched lines) and emit the matched pairs; recurse
  with the position *before the edit* (not the snake start).

  ### Tie-breaking convention

  When V[k−1] == V[k+1], the forward algorithm prefers "right" (delete
  from A). The backtrack mirrors this identically using the same
  condition. Changing the tie-break in one place without the other
  produces wrong results.

  ## API contract (unchanged from LCS implementation)

      iex> Exgit.Diff.LineDiff.matched_pairs(
      ...>   ["a", "b", "c"],
      ...>   ["a", "x", "c"]
      ...> )
      [{0, 0}, {2, 2}]
  """

  @type line_index :: non_neg_integer()
  @type matched_pairs :: [{line_index(), line_index()}]

  @doc """
  Compute matched line pairs between `a_lines` and `b_lines`.

  Returns a list of `{a_index, b_index}` tuples, 0-based, in
  strictly increasing order of both indices. Each index appears in
  at most one pair.

  ## Examples

      iex> Exgit.Diff.LineDiff.matched_pairs(
      ...>   ["a", "b", "c"],
      ...>   ["a", "x", "c"]
      ...> )
      [{0, 0}, {2, 2}]

      iex> Exgit.Diff.LineDiff.matched_pairs(["a", "b"], ["a", "b"])
      [{0, 0}, {1, 1}]

      iex> Exgit.Diff.LineDiff.matched_pairs([], ["a"])
      []

      iex> Exgit.Diff.LineDiff.matched_pairs(["a"], [])
      []
  """
  @spec matched_pairs([String.t()], [String.t()]) :: matched_pairs()
  def matched_pairs([], _), do: []
  def matched_pairs(_, []), do: []

  def matched_pairs(a_lines, b_lines) do
    a = List.to_tuple(a_lines)
    b = List.to_tuple(b_lines)
    n = tuple_size(a)
    m = tuple_size(b)

    # Fast path: identical sequences are the dominant case in blame
    # (most commits don't touch the file at all). O(N) scan.
    if n == m and identical?(a, b, 0, n) do
      for i <- 0..(n - 1), do: {i, i}
    else
      trace = forward(a, n, b, m)
      backtrack(trace, n, m)
    end
  end

  # ---------------------------------------------------------------------------
  # Forward phase — collect V-snapshots
  # ---------------------------------------------------------------------------
  #
  # Returns [v_0, v_1, ..., v_D] where v_d is the V map after processing
  # all diagonals at edit depth d. Each v maps diagonal k → furthest x.
  #
  # The initial sentinel V[1]=0 is the standard Myers trick: at d=0, k=0,
  # the condition k==−d is true, so we reach for V[k+1]=V[1]=0 and begin
  # the first snake from (0,0). The sentinel is not saved in the trace.

  defp forward(a, n, b, m) do
    v = %{1 => 0}
    do_forward(a, n, b, m, v, [], 0)
  end

  defp do_forward(a, n, b, m, v, trace, d) do
    {new_v, done} = step_d(a, n, b, m, v, d)
    # Prepend newest snapshot; reverse to chronological order on halt.
    new_trace = [new_v | trace]

    if done or d >= n + m do
      Enum.reverse(new_trace)
    else
      do_forward(a, n, b, m, new_v, new_trace, d + 1)
    end
  end

  # Process all diagonals for edit depth d. Returns {new_v, reached_end?}.
  #
  # Key invariant: all reads use the OUTER v (d−1 level snapshot),
  # never the accumulating new_v. Diagonals at the same d are independent.
  defp step_d(a, n, b, m, v, d) do
    Enum.reduce(Range.new(-d, d, 2), {v, false}, fn k, {new_v, any_done} ->
      x = choose_x(v, k, d)
      y = x - k
      {x, y} = snake(a, n, b, m, x, y)
      {Map.put(new_v, k, x), any_done or (x >= n and y >= m)}
    end)
  end

  # Starting x for diagonal k at depth d.
  # "Down" (from k+1): insert from B — y advances, x stays.
  # "Right" (from k−1): delete from A — x advances.
  # Prefer down when it gives a strictly larger x; prefer right on tie.
  # This tie-break is mirrored exactly in backtrack.
  defp choose_x(v, k, d) do
    cond do
      k == -d -> Map.get(v, k + 1, 0)
      k == d -> Map.get(v, k - 1, 0) + 1
      Map.get(v, k - 1, 0) < Map.get(v, k + 1, 0) -> Map.get(v, k + 1, 0)
      true -> Map.get(v, k - 1, 0) + 1
    end
  end

  # Advance diagonally while A[x] == B[y].
  defp snake(a, n, b, m, x, y) when x < n and y < m do
    if elem(a, x) == elem(b, y),
      do: snake(a, n, b, m, x + 1, y + 1),
      else: {x, y}
  end

  defp snake(_a, _n, _b, _m, x, y), do: {x, y}

  # ---------------------------------------------------------------------------
  # Backtrack phase — extract matched pairs from the trace
  # ---------------------------------------------------------------------------
  #
  # Walks from (n, m) back to (0, 0) through the V-snapshots in reverse,
  # mirroring the forward greedy choice at each level to find which
  # diagonal the edit came from.
  #
  # At each level d we:
  #   1. Determine the edit direction (down/right) using trace[d−1].
  #   2. Compute the snake start (position immediately after the edit).
  #   3. Collect matched pairs for the snake from snake_start to (x, y).
  #   4. Recurse with prev_pos — the position BEFORE the edit, which is
  #      the endpoint of the previous level's snake on the source diagonal.
  #      This is (px, px−k−1) for down and (px, px−k+1) for right, where
  #      px = prev_v[k±1].
  #
  # NOT snake_start: that would stay on diagonal k, ignoring the edit.

  defp backtrack(trace, n, m) do
    d = length(trace) - 1
    t = List.to_tuple(trace)
    do_backtrack(t, d, n, m, [])
  end

  # Reached origin — return accumulated pairs sorted.
  defp do_backtrack(_t, _d, 0, 0, pairs), do: Enum.sort(pairs)

  # d=0: entire remaining path is the initial snake from (0,0) to (x, x).
  # The snake length is x (same as y since we're on diagonal k=0).
  defp do_backtrack(_t, 0, x, _y, pairs) do
    prefix = for i <- 0..(x - 1), do: {i, i}
    Enum.sort(pairs ++ prefix)
  end

  defp do_backtrack(t, d, x, y, pairs) do
    k = x - y
    prev_v = elem(t, d - 1)

    if k == -d || (k != d && Map.get(prev_v, k - 1, 0) < Map.get(prev_v, k + 1, 0)) do
      # Edit at depth d was a DOWN move (insert from B) from diagonal k+1.
      # End of previous snake on diagonal k+1: (px, px − (k+1)).
      # After the down move (y += 1): (px, px − k).  ← snake start.
      # Snake runs from (px, px−k) to (x, y).
      px = Map.get(prev_v, k + 1, 0)
      snake_x = px
      snake_y = px - k
      snake_len = x - snake_x

      new_pairs =
        if snake_len > 0,
          do: for(i <- 0..(snake_len - 1), do: {snake_x + i, snake_y + i}),
          else: []

      # Recurse to position BEFORE the down move: (px, px−k−1) on diagonal k+1.
      do_backtrack(t, d - 1, px, px - k - 1, pairs ++ new_pairs)
    else
      # Edit at depth d was a RIGHT move (delete from A) from diagonal k−1.
      # End of previous snake on diagonal k−1: (px, px − (k−1)).
      # After the right move (x += 1): (px+1, px−k+1).  ← snake start.
      # Snake runs from (px+1, px−k+1) to (x, y).
      px = Map.get(prev_v, k - 1, 0)
      snake_x = px + 1
      snake_y = px - k + 1
      snake_len = x - snake_x

      new_pairs =
        if snake_len > 0,
          do: for(i <- 0..(snake_len - 1), do: {snake_x + i, snake_y + i}),
          else: []

      # Recurse to position BEFORE the right move: (px, px−k+1) on diagonal k−1.
      do_backtrack(t, d - 1, px, px - k + 1, pairs ++ new_pairs)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp identical?(_a, _b, i, n) when i >= n, do: true

  defp identical?(a, b, i, n) do
    if elem(a, i) == elem(b, i), do: identical?(a, b, i + 1, n), else: false
  end

  # ---------------------------------------------------------------------------
  # Convenience functions — unchanged API
  # ---------------------------------------------------------------------------

  @doc """
  Convenience: given matched pairs, return the list of 0-based
  indices in `b_lines` that are **new** (not carried from `a_lines`).
  """
  @spec b_additions(matched_pairs(), non_neg_integer()) :: [line_index()]
  def b_additions(pairs, b_length) do
    matched_b = MapSet.new(pairs, &elem(&1, 1))

    0..max(0, b_length - 1)
    |> Enum.to_list()
    |> Enum.reject(&MapSet.member?(matched_b, &1))
    |> then(fn list -> if b_length == 0, do: [], else: list end)
  end

  @doc """
  Convenience: for each 0-based index in `b_lines` that was carried
  from `a_lines`, return `{b_idx, a_idx}`.
  """
  @spec b_carryovers(matched_pairs()) :: [{line_index(), line_index()}]
  def b_carryovers(pairs) do
    Enum.map(pairs, fn {a_idx, b_idx} -> {b_idx, a_idx} end)
  end
end
