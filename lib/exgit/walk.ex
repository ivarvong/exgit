defmodule Exgit.Walk do
  @moduledoc """
  Commit graph traversal — `ancestors/3` and `merge_base/2`.

  ## Ordering

    * `:date` (default) — yields commits by descending author timestamp.
      A gb_sets-backed priority queue keeps the frontier in order.
    * `:topo` — Kahn-style topological order. A commit is never emitted
      before any of its descendants. Implementation: we first compute
      indegrees over the reachable subgraph (with respect to outgoing
      "parent" edges — i.e. a commit's indegree counts how many of its
      known descendants have not yet been emitted); then we drain
      commits with indegree zero and decrement parents.

  ## Merge base

  `merge_base/2` uses a frontier-marking BFS (git's classic
  "paint-down" algorithm). No ancestor set is materialized in full;
  the search stops as soon as the frontier is dominated by known
  common ancestors. This is O(commits until first LCA found), not
  O(|ancestors(a)| + |ancestors(b)|).
  """

  alias Exgit.Object.Commit

  # Compiled once at module load; reused on every
  # `parse_timestamp/1`. Previously compiled per call — at ~1M
  # commits per full-history walk of a large repo this was
  # measurable.
  @timestamp_regex ~r/(\d+)\s+[+-]\d{4}$/

  @type repo :: %{object_store: term()}

  @spec ancestors(repo(), binary(), keyword()) :: Enumerable.t()
  def ancestors(repo, start_sha, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    order = Keyword.get(opts, :order, :date)

    stream =
      case order do
        :date -> date_stream(repo, start_sha)
        :topo -> topo_stream(repo, start_sha)
      end

    if limit, do: Stream.take(stream, limit), else: stream
  end

  @doc """
  Find a **single** lowest-common-ancestor (LCA) commit for the given
  SHAs.

  When multiple LCAs exist (a criss-cross merge has two), `merge_base/2`
  picks one deterministically:

    * newest by author timestamp, wins
    * ties broken by SHA (ascending)

  This is **not identical to `git merge-base`'s tie-break** in every
  case: git uses a traversal-order-dependent choice that can be hard
  to replicate without cloning git's exact implementation. Both
  libraries return a semantically-correct LCA; for workflows that
  need the full set (e.g. a three-way merge), use
  `merge_base_all/2`.

  Returns `{:ok, sha}` on success or `{:error, :none}` when the
  commits share no common ancestor.
  """
  @spec merge_base(repo(), [binary()]) :: {:ok, binary()} | {:error, :none}
  def merge_base(_repo, []), do: {:error, :none}
  def merge_base(_repo, [sha]), do: {:ok, sha}

  def merge_base(repo, [a, b]) do
    find_merge_base(repo, a, b)
  end

  def merge_base(repo, [a, b | rest]) do
    case find_merge_base(repo, a, b) do
      {:ok, base} -> merge_base(repo, [base | rest])
      error -> error
    end
  end

  @doc """
  Find **all** lowest-common-ancestor commits for a pair of SHAs.

  Equivalent to `git merge-base --all` — returns every commit that
  is an ancestor of both inputs AND is not an ancestor of any other
  such commit. Most histories return a singleton list; criss-cross
  merges return 2+.

  Currently only supports pairs. For N > 2, compose pairwise.
  """
  @spec merge_base_all(repo(), [binary()]) :: {:ok, [binary()]} | {:error, :none}
  def merge_base_all(_repo, []), do: {:error, :none}
  def merge_base_all(_repo, [sha]), do: {:ok, [sha]}

  def merge_base_all(repo, [a, b]) do
    case find_merge_base_raw(repo, a, b) do
      {:ok, []} -> {:error, :none}
      {:ok, list} -> {:ok, list}
      error -> error
    end
  end

  # --- Date-ordered walk ---

  defp date_stream(repo, start_sha) do
    Stream.resource(
      fn ->
        case get_commit(repo, start_sha) do
          {:ok, commit} ->
            queue =
              :gb_sets.empty()
              |> enqueue_date({commit, start_sha})

            {queue, MapSet.new([start_sha])}

          _ ->
            {:gb_sets.empty(), MapSet.new()}
        end
      end,
      fn {queue, seen} -> date_step(repo, queue, seen) end,
      fn _ -> :ok end
    )
  end

  defp date_step(repo, queue, seen) do
    if :gb_sets.is_empty(queue) do
      {:halt, {queue, seen}}
    else
      {{_ts, _tiebreak, _sha, commit}, queue} = :gb_sets.take_smallest(queue)

      {queue, seen} =
        Enum.reduce(Commit.parents(commit), {queue, seen}, fn parent_sha, {q, s} ->
          if MapSet.member?(s, parent_sha) do
            {q, s}
          else
            case get_commit(repo, parent_sha) do
              {:ok, pc} -> {enqueue_date(q, {pc, parent_sha}), MapSet.put(s, parent_sha)}
              _ -> {q, s}
            end
          end
        end)

      {[commit], {queue, seen}}
    end
  end

  defp enqueue_date(queue, {commit, sha}) do
    ts = parse_timestamp(Commit.author(commit))
    # gb_sets is min-first; use negative timestamp for max-first. Include
    # a tiebreak on sha to allow equal-timestamp commits to coexist.
    :gb_sets.add({-ts, sha, sha, commit}, queue)
  end

  # --- Topo-ordered walk (Kahn) ---
  #
  # Compute indegrees once up-front over the reachable subgraph with
  # respect to the "descendant" relation (parent-edges reversed). Then
  # drain commits with indegree 0, each decrementing its parents'
  # indegree.

  defp topo_stream(repo, start_sha) do
    case get_commit(repo, start_sha) do
      {:ok, _} ->
        {commits, indegrees} = compute_topo_state(repo, start_sha)

        Stream.resource(
          fn ->
            # Ready = nodes with indegree 0. Initially only `start_sha`.
            ready = :queue.from_list([start_sha])
            {commits, indegrees, ready}
          end,
          fn {commits, indegrees, ready} -> topo_step(commits, indegrees, ready) end,
          fn _ -> :ok end
        )

      _ ->
        Stream.resource(fn -> nil end, fn _ -> {:halt, nil} end, fn _ -> :ok end)
    end
  end

  defp topo_step(_commits, _indegrees, :done), do: {:halt, :done}

  defp topo_step(commits, indegrees, ready) do
    case :queue.out(ready) do
      {:empty, _} ->
        {:halt, {commits, indegrees, :done}}

      {{:value, sha}, ready} ->
        commit = Map.fetch!(commits, sha)

        {indegrees, ready} =
          Enum.reduce(Commit.parents(commit), {indegrees, ready}, fn p, {ids, q} ->
            case Map.fetch(ids, p) do
              {:ok, 1} -> {Map.delete(ids, p), :queue.in(p, q)}
              {:ok, n} -> {Map.put(ids, p, n - 1), q}
              :error -> {ids, q}
            end
          end)

        {[commit], {commits, indegrees, ready}}
    end
  end

  # Walk the reachable subgraph, returning:
  #   commits :: %{sha => Commit.t()}     — all reachable commits
  #   indegrees :: %{sha => non_neg_integer()} — in-edges from descendants
  defp compute_topo_state(repo, start_sha) do
    # BFS frontier; indegree map counts edges into each node.
    do_compute_topo([start_sha], repo, %{}, %{start_sha => 0})
  end

  defp do_compute_topo([], _repo, commits, indegrees), do: {commits, indegrees}

  defp do_compute_topo([sha | rest], repo, commits, indegrees) do
    if Map.has_key?(commits, sha) do
      do_compute_topo(rest, repo, commits, indegrees)
    else
      case get_commit(repo, sha) do
        {:ok, commit} ->
          parents = Commit.parents(commit)
          commits = Map.put(commits, sha, commit)

          indegrees =
            Enum.reduce(parents, indegrees, fn p, acc ->
              Map.update(acc, p, 1, &(&1 + 1))
            end)

          do_compute_topo(parents ++ rest, repo, commits, indegrees)

        _ ->
          do_compute_topo(rest, repo, commits, indegrees)
      end
    end
  end

  defp parse_timestamp(author_line) do
    case Regex.run(@timestamp_regex, author_line) do
      [_, ts] -> String.to_integer(ts)
      _ -> 0
    end
  end

  # --- Merge base (frontier BFS) ---

  # State:
  #   flags :: %{sha => bitmask} where bit 0 = reachable from A, bit 1 = from B,
  #                              bit 2 = known stale (descendant of a candidate)
  #   queue: commits to visit, ordered by author timestamp (newest first)
  #   candidates: set of common ancestors seen so far
  @flag_a 1
  @flag_b 2
  @flag_stale 4

  defp find_merge_base(repo, sha_a, sha_b) do
    case find_merge_base_raw(repo, sha_a, sha_b) do
      {:ok, []} -> {:error, :none}
      {:ok, candidates} -> {:ok, pick_best_candidate(repo, candidates)}
      error -> error
    end
  end

  # Run the frontier BFS and return the raw candidate list without
  # picking a single winner. Used by `find_merge_base/3` (which then
  # calls `pick_best_candidate/2`) and by the public
  # `merge_base_all/2`.
  defp find_merge_base_raw(repo, sha_a, sha_b) do
    flags =
      %{}
      |> Map.update(sha_a, @flag_a, &Bitwise.bor(&1, @flag_a))
      |> Map.update(sha_b, @flag_b, &Bitwise.bor(&1, @flag_b))

    {queue, in_queue_count, stale_in_queue} =
      enqueue_seed(:gb_sets.empty(), repo, sha_a, flags)
      |> enqueue_seed_second(repo, sha_a, sha_b, flags)

    state = %{
      queue: queue,
      flags: flags,
      candidates: MapSet.new(),
      in_queue: in_queue_count,
      stale_in_queue: stale_in_queue
    }

    mb_loop(repo, state)
  end

  # When the frontier BFS produces multiple candidate LCAs (classic
  # criss-cross merge), `hd(candidates)` is nondeterministic — MapSet
  # iteration order depends on insertion hashing.
  #
  # Git's `merge-base` resolves ties by picking the newest commit by
  # author timestamp, with SHA as a stable tiebreaker. Emulate that
  # so single-base queries produce git-compatible output. Callers who
  # want the full set of LCAs should use `merge_base_all/2` (future
  # addition).
  defp pick_best_candidate(repo, candidates) do
    candidates
    |> Enum.map(fn sha ->
      ts =
        case get_commit(repo, sha) do
          {:ok, c} -> parse_timestamp(Commit.author(c))
          _ -> 0
        end

      {sha, ts}
    end)
    |> Enum.sort_by(fn {sha, ts} -> {-ts, sha} end)
    |> hd()
    |> elem(0)
  end

  defp enqueue_seed(queue, repo, sha, _flags) do
    case get_commit(repo, sha) do
      {:ok, commit} ->
        ts = parse_timestamp(Commit.author(commit))
        q = :gb_sets.add({-ts, sha, commit}, queue)
        {q, 1, 0}

      _ ->
        {queue, 0, 0}
    end
  end

  defp enqueue_seed_second({queue, n, stale}, _repo, same, same, _flags), do: {queue, n, stale}

  defp enqueue_seed_second({queue, n, stale}, repo, _a, b, flags) do
    case get_commit(repo, b) do
      {:ok, commit} ->
        ts = parse_timestamp(Commit.author(commit))
        q = :gb_sets.add({-ts, b, commit}, queue)
        stale_delta = if Bitwise.band(Map.get(flags, b, 0), @flag_stale) != 0, do: 1, else: 0
        {q, n + 1, stale + stale_delta}

      _ ->
        {queue, n, stale}
    end
  end

  # Enqueue a parent for merge-base traversal, updating the
  # in-queue and stale-in-queue counters. Returns `{queue, n, stale}`.
  defp enqueue_parent({queue, n, stale}, repo, sha, flags) do
    case get_commit(repo, sha) do
      {:ok, commit} ->
        ts = parse_timestamp(Commit.author(commit))
        q = :gb_sets.add({-ts, sha, commit}, queue)
        is_stale = Bitwise.band(Map.get(flags, sha, 0), @flag_stale) != 0
        {q, n + 1, if(is_stale, do: stale + 1, else: stale)}

      _ ->
        {queue, n, stale}
    end
  end

  defp mb_loop(repo, %{queue: queue} = state) do
    if :gb_sets.is_empty(queue) do
      {:ok, MapSet.to_list(state.candidates)}
    else
      {{_ts, sha, commit}, queue} = :gb_sets.take_smallest(queue)

      f = Map.fetch!(state.flags, sha)
      was_stale = Bitwise.band(f, @flag_stale) != 0

      # Decrement in-queue counters for the item we just popped.
      in_queue = state.in_queue - 1
      stale_in_queue = if was_stale, do: state.stale_in_queue - 1, else: state.stale_in_queue

      both = Bitwise.band(@flag_a, f) != 0 and Bitwise.band(@flag_b, f) != 0

      {candidates, propagate_flag} =
        if both and not was_stale do
          {MapSet.put(state.candidates, sha), @flag_stale}
        else
          {state.candidates, 0}
        end

      # Early termination in O(1): if every remaining entry is stale,
      # there's no way to find a better candidate. The old scan over
      # the whole gb_set for this check was O(|queue|) per iteration,
      # making merge_base O(|queue|^2) in the worst case. Now we
      # maintain stale_in_queue incrementally.
      if in_queue > 0 and in_queue == stale_in_queue do
        {:ok, MapSet.to_list(candidates)}
      else
        {flags, {queue, in_queue, stale_in_queue}} =
          Enum.reduce(
            Commit.parents(commit),
            {state.flags, {queue, in_queue, stale_in_queue}},
            fn p, {fs, q_state} ->
              pf = Bitwise.bor(f, propagate_flag)
              old = Map.get(fs, p, 0)
              new_flags = Bitwise.bor(old, pf)

              fs = Map.put(fs, p, new_flags)

              q_state =
                if new_flags != old do
                  enqueue_parent(q_state, repo, p, fs)
                else
                  q_state
                end

              {fs, q_state}
            end
          )

        mb_loop(repo, %{
          queue: queue,
          flags: flags,
          candidates: candidates,
          in_queue: in_queue,
          stale_in_queue: stale_in_queue
        })
      end
    end
  end

  # --- Helpers ---

  defp get_commit(%{object_store: store}, sha) do
    case Exgit.ObjectStore.get(store, sha) do
      {:ok, %Commit{} = commit} -> {:ok, commit}
      {:ok, _} -> {:error, :not_a_commit}
      error -> error
    end
  end
end
