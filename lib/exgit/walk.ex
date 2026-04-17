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
    case Regex.run(~r/(\d+)\s+[+-]\d{4}$/, author_line) do
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
    # Merge both "seed" flags so that seeding the same sha twice produces
    # a commit already tagged as both-reachable.
    flags =
      %{}
      |> Map.update(sha_a, @flag_a, &Bitwise.bor(&1, @flag_a))
      |> Map.update(sha_b, @flag_b, &Bitwise.bor(&1, @flag_b))

    queue =
      :gb_sets.empty()
      |> maybe_enqueue_mb(repo, sha_a)
      |> if_different_enqueue(sha_a, sha_b, repo)

    case mb_loop(repo, queue, flags, MapSet.new()) do
      {:ok, candidates} when candidates != [] ->
        {:ok, hd(candidates)}

      {:ok, _} ->
        {:error, :none}

      :none ->
        {:error, :none}
    end
  end

  defp if_different_enqueue(queue, same, same, _repo), do: queue
  defp if_different_enqueue(queue, _a, b, repo), do: maybe_enqueue_mb(queue, repo, b)

  defp maybe_enqueue_mb(queue, repo, sha) do
    case get_commit(repo, sha) do
      {:ok, commit} ->
        ts = parse_timestamp(Commit.author(commit))
        :gb_sets.add({-ts, sha, commit}, queue)

      _ ->
        queue
    end
  end

  defp mb_loop(repo, queue, flags, candidates) do
    if :gb_sets.is_empty(queue) do
      {:ok, MapSet.to_list(candidates)}
    else
      {{_ts, sha, commit}, queue} = :gb_sets.take_smallest(queue)

      f = Map.fetch!(flags, sha)
      both = Bitwise.band(@flag_a, f) != 0 and Bitwise.band(@flag_b, f) != 0

      {candidates, propagate_flag} =
        if both and Bitwise.band(f, @flag_stale) == 0 do
          # New candidate LCA. Mark its ancestors stale so we don't pick
          # something further back.
          {MapSet.put(candidates, sha), @flag_stale}
        else
          {candidates, 0}
        end

      # Early termination: if every item remaining in the queue is stale,
      # we can stop.
      if not :gb_sets.is_empty(queue) and all_stale?(queue, flags) do
        {:ok, MapSet.to_list(candidates)}
      else
        {flags, queue} =
          Enum.reduce(Commit.parents(commit), {flags, queue}, fn p, {fs, q} ->
            pf = Bitwise.bor(f, propagate_flag)
            old = Map.get(fs, p, 0)
            new_flags = Bitwise.bor(old, pf)

            fs = Map.put(fs, p, new_flags)

            q =
              if new_flags != old do
                maybe_enqueue_mb(q, repo, p)
              else
                q
              end

            {fs, q}
          end)

        mb_loop(repo, queue, flags, candidates)
      end
    end
  end

  defp all_stale?(queue, flags) do
    Enum.all?(:gb_sets.to_list(queue), fn {_ts, sha, _} ->
      Bitwise.band(Map.get(flags, sha, 0), @flag_stale) != 0
    end)
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
