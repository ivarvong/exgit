defmodule Exgit.Diff do
  @moduledoc """
  Compare two git trees and return a list of changes.

  Changes are returned as maps with explicit keys so callers can pattern
  match on the operation, path, modes, and SHAs:

      %{op: :added,             path: String.t(), new_mode: String.t(), new_sha: binary()}
      %{op: :removed,           path: String.t(), old_mode: String.t(), old_sha: binary()}
      %{op: :modified,          path: String.t(), old_mode: String.t(), new_mode: String.t(),
                                old_sha: binary(), new_sha: binary()}
      %{op: :mode_changed,      path: String.t(), old_mode: String.t(), new_mode: String.t(),
                                old_sha: binary(), new_sha: binary()}
      %{op: :submodule_change,  path: String.t(), old_sha: binary(), new_sha: binary()}
      %{op: :type_changed,      path: String.t(), old_mode: String.t(), new_mode: String.t(),
                                old_sha: binary(), new_sha: binary()}

  For backward compatibility the old 4-tuple shape is still supported via
  `trees_tuple/4` — new code should prefer `trees/4`.
  """

  alias Exgit.Object.Tree

  @type change ::
          %{required(:op) => atom(), required(:path) => String.t(), optional(atom()) => term()}

  @spec trees(term(), binary() | nil, binary() | nil, keyword()) ::
          {:ok, [change()]} | {:error, term()}
  def trees(repo, tree_a_sha, tree_b_sha, opts \\ [])

  def trees(_repo, same, same, _opts) when not is_nil(same), do: {:ok, []}

  def trees(repo, nil, tree_b_sha, opts) do
    with {:ok, tree_b} <- get_tree(repo, tree_b_sha) do
      prefix = Keyword.get(opts, :prefix, "")
      {:ok, all_added(repo, tree_b.entries, prefix)}
    end
  end

  def trees(repo, tree_a_sha, nil, opts) do
    with {:ok, tree_a} <- get_tree(repo, tree_a_sha) do
      prefix = Keyword.get(opts, :prefix, "")
      {:ok, all_removed(repo, tree_a.entries, prefix)}
    end
  end

  def trees(repo, tree_a_sha, tree_b_sha, opts) do
    with {:ok, tree_a} <- get_tree(repo, tree_a_sha),
         {:ok, tree_b} <- get_tree(repo, tree_b_sha) do
      prefix = Keyword.get(opts, :prefix, "")
      {:ok, diff_entries(repo, tree_a.entries, tree_b.entries, prefix)}
    end
  end

  # --- Internal ---

  defp diff_entries(repo, entries_a, entries_b, prefix) do
    map_a = Map.new(entries_a, fn {_mode, name, _sha} = e -> {name, e} end)
    map_b = Map.new(entries_b, fn {_mode, name, _sha} = e -> {name, e} end)
    all_names = MapSet.union(MapSet.new(Map.keys(map_a)), MapSet.new(Map.keys(map_b)))

    all_names
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      a = Map.get(map_a, name)
      b = Map.get(map_b, name)
      path = join_path(prefix, name)
      diff_entry(repo, a, b, path)
    end)
  end

  # New entry on the right side
  defp diff_entry(repo, nil, {mode_b, _name, sha_b}, path) do
    if mode_b == "40000" do
      case get_tree(repo, sha_b) do
        {:ok, tree} -> all_added(repo, tree.entries, path)
        _ -> [added_change(path, mode_b, sha_b)]
      end
    else
      [added_change(path, mode_b, sha_b)]
    end
  end

  # Removed entry on the left side
  defp diff_entry(repo, {mode_a, _name, sha_a}, nil, path) do
    if mode_a == "40000" do
      case get_tree(repo, sha_a) do
        {:ok, tree} -> all_removed(repo, tree.entries, path)
        _ -> [removed_change(path, mode_a, sha_a)]
      end
    else
      [removed_change(path, mode_a, sha_a)]
    end
  end

  defp diff_entry(repo, {mode_a, _name, sha_a}, {mode_b, _name_b, sha_b}, path) do
    cond do
      sha_a == sha_b and mode_a == mode_b ->
        []

      # Submodules (gitlinks): both sides are 160000 → :submodule_change
      mode_a == "160000" and mode_b == "160000" ->
        [
          %{
            op: :submodule_change,
            path: path,
            old_sha: sha_a,
            new_sha: sha_b
          }
        ]

      # Both sides are trees → recurse.
      mode_a == "40000" and mode_b == "40000" ->
        case {get_tree(repo, sha_a), get_tree(repo, sha_b)} do
          {{:ok, ta}, {:ok, tb}} -> diff_entries(repo, ta.entries, tb.entries, path)
          _ -> [modified_change(path, mode_a, sha_a, mode_b, sha_b)]
        end

      # Type change between tree and non-tree.
      mode_a == "40000" or mode_b == "40000" ->
        [
          %{
            op: :type_changed,
            path: path,
            old_mode: mode_a,
            new_mode: mode_b,
            old_sha: sha_a,
            new_sha: sha_b
          }
        ]

      # Same content, different mode: :mode_changed
      sha_a == sha_b ->
        [
          %{
            op: :mode_changed,
            path: path,
            old_mode: mode_a,
            new_mode: mode_b,
            old_sha: sha_a,
            new_sha: sha_b
          }
        ]

      # Ordinary content change.
      true ->
        [modified_change(path, mode_a, sha_a, mode_b, sha_b)]
    end
  end

  defp added_change(path, mode, sha),
    do: %{op: :added, path: path, new_mode: mode, new_sha: sha, old_mode: nil, old_sha: nil}

  defp removed_change(path, mode, sha),
    do: %{op: :removed, path: path, old_mode: mode, old_sha: sha, new_mode: nil, new_sha: nil}

  defp modified_change(path, mode_a, sha_a, mode_b, sha_b),
    do: %{
      op: :modified,
      path: path,
      old_mode: mode_a,
      new_mode: mode_b,
      old_sha: sha_a,
      new_sha: sha_b
    }

  defp all_added(repo, entries, prefix) do
    Enum.flat_map(entries, fn {mode, name, sha} ->
      path = join_path(prefix, name)

      if mode == "40000" do
        case get_tree(repo, sha) do
          {:ok, tree} -> all_added(repo, tree.entries, path)
          _ -> [added_change(path, mode, sha)]
        end
      else
        [added_change(path, mode, sha)]
      end
    end)
  end

  defp all_removed(repo, entries, prefix) do
    Enum.flat_map(entries, fn {mode, name, sha} ->
      path = join_path(prefix, name)

      if mode == "40000" do
        case get_tree(repo, sha) do
          {:ok, tree} -> all_removed(repo, tree.entries, path)
          _ -> [removed_change(path, mode, sha)]
        end
      else
        [removed_change(path, mode, sha)]
      end
    end)
  end

  defp join_path("", name), do: name
  defp join_path(prefix, name), do: prefix <> "/" <> name

  defp get_tree(%{object_store: store}, sha) do
    case Exgit.ObjectStore.get(store, sha) do
      {:ok, %Tree{} = tree} -> {:ok, tree}
      {:ok, _} -> {:error, :not_a_tree}
      error -> error
    end
  end
end
