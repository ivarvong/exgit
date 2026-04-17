defmodule Exgit.Test.CommitGraph do
  @moduledoc """
  Helpers for building in-memory commit graphs for walk / merge_base /
  reachability tests.

  A graph is specified as a map `%{name => parents_names}` plus an optional
  timestamp per commit. `build/1` returns `{repo, name_to_sha}`.
  """

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore

  @doc """
  Build a repo from a map of `name => [parent_names]`. Timestamps default
  to the position in topological order (lower index = older).

  Options:
    * `:timestamps` - map of name => unix_seconds to override defaults
  """
  def build(graph, opts \\ []) do
    order = topo_sort(graph)
    timestamps = Keyword.get(opts, :timestamps, %{})

    base_ts = 1_700_000_000

    # A single shared empty tree/blob so commits differ only by parents/name.
    empty_blob = Blob.new("")
    store = ObjectStore.Memory.new()
    {:ok, blob_sha, store} = ObjectStore.put(store, empty_blob)

    {store, name_to_sha} =
      Enum.reduce(Enum.with_index(order), {store, %{}}, fn {name, idx}, {store_acc, sha_map} ->
        ts = Map.get(timestamps, name, base_ts + idx)

        # Tree contains one blob keyed by commit name for determinism.
        tree = Tree.new([{"100644", "n-#{name}", blob_sha}])
        {:ok, tree_sha, store_acc} = ObjectStore.put(store_acc, tree)

        parents =
          graph
          |> Map.get(name, [])
          |> Enum.map(&Map.fetch!(sha_map, &1))

        commit =
          Commit.new(
            tree: tree_sha,
            parents: parents,
            author: "X <x@example.com> #{ts} +0000",
            committer: "X <x@example.com> #{ts} +0000",
            message: "#{name}\n"
          )

        {:ok, sha, store_acc} = ObjectStore.put(store_acc, commit)
        {store_acc, Map.put(sha_map, name, sha)}
      end)

    repo = %{object_store: store}
    {repo, name_to_sha}
  end

  @doc "Resolve a list of commit names to their SHAs in the given sha map."
  def shas(name_to_sha, names), do: Enum.map(names, &Map.fetch!(name_to_sha, &1))

  @doc "Reverse lookup: SHA → name. Raises if unknown."
  def name_of(name_to_sha, sha) do
    {name, _} = Enum.find(name_to_sha, fn {_, s} -> s == sha end) || raise "no name for sha"
    name
  end

  # Parents-before-children ordering. We return a linear order where a
  # node is never listed before any of its parents. Uses a simple
  # iterative post-order DFS; the test helper calls this only to decide
  # the order we write objects into the store (parents first), not to
  # validate exgit itself, so correctness under arbitrary cycles isn't
  # required — only that it handles valid DAGs.
  defp topo_sort(graph) do
    nodes = Map.keys(graph)

    {order, _} =
      Enum.reduce(nodes, {[], MapSet.new()}, fn n, {acc, seen} ->
        dfs(n, graph, acc, seen)
      end)

    Enum.reverse(order)
  end

  defp dfs(node, graph, acc, seen) do
    if MapSet.member?(seen, node) do
      {acc, seen}
    else
      seen = MapSet.put(seen, node)
      parents = Map.get(graph, node, [])

      {acc, seen} =
        Enum.reduce(parents, {acc, seen}, fn p, {a, s} -> dfs(p, graph, a, s) end)

      {[node | acc], seen}
    end
  end
end
