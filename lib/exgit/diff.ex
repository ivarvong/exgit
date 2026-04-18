defmodule Exgit.Diff do
  # Silence Dialyzer false positives on MapSet opacity — see the
  # equivalent comment in `Exgit.Walk`. The `Ctx.seen` field is
  # declared as `MapSet.t()` but Dialyzer sometimes surfaces the
  # internal :sets/map union at call sites.
  @dialyzer :no_opaque

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

  ## Options

    * `:prefix` — path prefix for the produced change entries. Default `""`.
    * `:max_depth` — maximum tree recursion depth. Protects against a
      hostile tree with a circular reference or a pathological nesting
      that would overflow the stack. Default 256 (git itself caps
      around 4096).
    * `:max_changes` — cap the number of change entries. Prevents
      a single `Diff.trees` call from producing millions of entries
      on a hostile input. Default `nil` (unbounded; caller takes
      responsibility).

  ## Defense in depth

  `Diff.trees/4` is the one path that walks arbitrary (possibly
  remote-sourced) tree graphs recursively. It must not overflow the
  stack or loop forever on a tree object that references itself
  (directly or indirectly). The `:max_depth` cap is the guard; a
  tree that exceeds it returns `{:error, {:max_depth_exceeded, n}}`
  so callers can distinguish "legitimately deep" from "hostile".
  """

  alias Exgit.Object.Tree

  @default_max_depth 256

  @type change ::
          %{required(:op) => atom(), required(:path) => String.t(), optional(atom()) => term()}

  # Internal traversal context. Broken out as its own struct (rather
  # than a plain map) so Dialyzer retains opacity on the `seen`
  # MapSet.t() field across recursive helpers.
  defmodule Ctx do
    @moduledoc false
    @enforce_keys [:prefix, :depth, :max_depth, :seen]
    defstruct [:prefix, :depth, :max_depth, :seen, max_changes: nil]

    @type t :: %__MODULE__{
            prefix: String.t(),
            depth: non_neg_integer(),
            max_depth: pos_integer(),
            max_changes: pos_integer() | nil,
            seen: MapSet.t()
          }
  end

  @spec trees(term(), binary() | nil, binary() | nil, keyword()) ::
          {:ok, [change()]} | {:error, term()}
  def trees(repo, tree_a_sha, tree_b_sha, opts \\ [])

  def trees(_repo, same, same, _opts) when not is_nil(same), do: {:ok, []}

  def trees(repo, nil, tree_b_sha, opts) do
    with {:ok, tree_b} <- get_tree(repo, tree_b_sha) do
      ctx = context(opts)
      walk_side(repo, tree_b.entries, ctx, :added)
    end
  end

  def trees(repo, tree_a_sha, nil, opts) do
    with {:ok, tree_a} <- get_tree(repo, tree_a_sha) do
      ctx = context(opts)
      walk_side(repo, tree_a.entries, ctx, :removed)
    end
  end

  def trees(repo, tree_a_sha, tree_b_sha, opts) do
    with {:ok, tree_a} <- get_tree(repo, tree_a_sha),
         {:ok, tree_b} <- get_tree(repo, tree_b_sha) do
      ctx = context(opts)

      case diff_entries(repo, tree_a.entries, tree_b.entries, ctx) do
        {:ok, changes} -> {:ok, changes}
        {:error, _} = err -> err
      end
    end
  end

  # --- Context ---

  defp context(opts) do
    %Ctx{
      prefix: Keyword.get(opts, :prefix, ""),
      depth: 0,
      max_depth: Keyword.get(opts, :max_depth, @default_max_depth),
      max_changes: Keyword.get(opts, :max_changes),
      seen: MapSet.new()
    }
  end

  defp descend(%Ctx{} = ctx, path, sub_sha) do
    cond do
      ctx.depth >= ctx.max_depth ->
        {:error, {:max_depth_exceeded, ctx.max_depth}}

      MapSet.member?(ctx.seen, sub_sha) ->
        # Tree SHA already visited on this descent path — a cycle.
        # Real git trees form a DAG, not a cyclic graph, but a
        # hostile pack can contain a crafted cycle. Refuse.
        {:error, {:tree_cycle, Base.encode16(sub_sha, case: :lower)}}

      true ->
        {:ok,
         %Ctx{
           ctx
           | prefix: path,
             depth: ctx.depth + 1,
             seen: MapSet.put(ctx.seen, sub_sha)
         }}
    end
  end

  defp walk_side(repo, entries, ctx, side) do
    case collect_side(repo, entries, ctx, side, []) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp collect_side(_repo, [], _ctx, _side, acc), do: {:ok, acc}

  defp collect_side(repo, [{mode, name, sha} | rest], ctx, side, acc) do
    path = join_path(ctx.prefix, name)

    with :ok <- check_change_cap(acc, ctx),
         {:ok, acc} <- emit_side(repo, mode, path, sha, ctx, side, acc) do
      collect_side(repo, rest, ctx, side, acc)
    end
  end

  defp emit_side(repo, "40000", path, sha, ctx, side, acc) do
    case get_tree(repo, sha) do
      {:ok, tree} ->
        case descend(ctx, path, sha) do
          {:ok, sub_ctx} ->
            case collect_side(repo, tree.entries, sub_ctx, side, acc) do
              {:ok, _} = ok -> ok
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            err
        end

      _ ->
        # Tree missing or malformed — surface as a leaf-level change
        # rather than silently skipping the branch.
        {:ok, [side_change(side, path, "40000", sha) | acc]}
    end
  end

  defp emit_side(_repo, mode, path, sha, _ctx, side, acc) do
    {:ok, [side_change(side, path, mode, sha) | acc]}
  end

  defp side_change(:added, path, mode, sha), do: added_change(path, mode, sha)
  defp side_change(:removed, path, mode, sha), do: removed_change(path, mode, sha)

  defp check_change_cap(_acc, %{max_changes: nil}), do: :ok

  defp check_change_cap(acc, %{max_changes: max}) when length(acc) >= max,
    do: {:error, {:max_changes_exceeded, max}}

  defp check_change_cap(_, _), do: :ok

  # --- Pairwise diff ---

  defp diff_entries(repo, entries_a, entries_b, ctx) do
    map_a = Map.new(entries_a, fn {_mode, name, _sha} = e -> {name, e} end)
    map_b = Map.new(entries_b, fn {_mode, name, _sha} = e -> {name, e} end)
    all_names = MapSet.union(MapSet.new(Map.keys(map_a)), MapSet.new(Map.keys(map_b)))

    sorted_names = Enum.sort(all_names)

    case reduce_names(repo, sorted_names, map_a, map_b, ctx, []) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp reduce_names(_repo, [], _map_a, _map_b, _ctx, acc), do: {:ok, acc}

  defp reduce_names(repo, [name | rest], map_a, map_b, ctx, acc) do
    a = Map.get(map_a, name)
    b = Map.get(map_b, name)
    path = join_path(ctx.prefix, name)

    with :ok <- check_change_cap(acc, ctx),
         {:ok, new_acc} <- diff_entry(repo, a, b, path, ctx, acc) do
      reduce_names(repo, rest, map_a, map_b, ctx, new_acc)
    end
  end

  # New entry on the right side — tree-side "added" expansion.
  defp diff_entry(repo, nil, {mode_b, _name, sha_b}, path, ctx, acc) do
    if mode_b == "40000" do
      expand_side(repo, path, sha_b, ctx, :added, acc)
    else
      {:ok, [added_change(path, mode_b, sha_b) | acc]}
    end
  end

  # Removed entry on the left side.
  defp diff_entry(repo, {mode_a, _name, sha_a}, nil, path, ctx, acc) do
    if mode_a == "40000" do
      expand_side(repo, path, sha_a, ctx, :removed, acc)
    else
      {:ok, [removed_change(path, mode_a, sha_a) | acc]}
    end
  end

  defp diff_entry(repo, {mode_a, _name, sha_a}, {mode_b, _name_b, sha_b}, path, ctx, acc) do
    cond do
      sha_a == sha_b and mode_a == mode_b ->
        {:ok, acc}

      # Submodules (gitlinks): both sides are 160000 → :submodule_change
      mode_a == "160000" and mode_b == "160000" ->
        {:ok,
         [
           %{
             op: :submodule_change,
             path: path,
             old_sha: sha_a,
             new_sha: sha_b
           }
           | acc
         ]}

      # Both sides are trees → recurse. We descend under cycle/depth
      # guards; a failure on either side's tree returns an error
      # instead of the prior silent `:modified` fallback (which hid
      # inconsistency from callers).
      mode_a == "40000" and mode_b == "40000" ->
        descend_and_diff(repo, sha_a, sha_b, path, ctx, acc)

      # Type change between tree and non-tree.
      mode_a == "40000" or mode_b == "40000" ->
        {:ok,
         [
           %{
             op: :type_changed,
             path: path,
             old_mode: mode_a,
             new_mode: mode_b,
             old_sha: sha_a,
             new_sha: sha_b
           }
           | acc
         ]}

      # Same content, different mode: :mode_changed.
      sha_a == sha_b ->
        {:ok,
         [
           %{
             op: :mode_changed,
             path: path,
             old_mode: mode_a,
             new_mode: mode_b,
             old_sha: sha_a,
             new_sha: sha_b
           }
           | acc
         ]}

      # Ordinary content change.
      true ->
        {:ok, [modified_change(path, mode_a, sha_a, mode_b, sha_b) | acc]}
    end
  end

  # Recurse into two tree children, guarding depth + cycles on BOTH
  # sides. We pick a single descend call per recursion, using the
  # lexicographically-smaller SHA as the `seen` token — it doesn't
  # matter which, so long as we guard against self-cycles.
  defp descend_and_diff(repo, sha_a, sha_b, path, %Ctx{} = ctx, acc) do
    # All clauses in the `with` return `{:ok, _} | {:error, _}`, so
    # the `else` block only needs to catch the error shape. Pin the
    # `%Ctx{}` struct on every `sub_ctx` binding so Elixir 1.19's
    # type checker retains field shape across the chain.
    with {:ok, ta} <- get_tree(repo, sha_a),
         {:ok, tb} <- get_tree(repo, sha_b),
         {:ok, %Ctx{} = sub_ctx} <- descend(ctx, path, sha_a),
         {:ok, %Ctx{} = sub_ctx} <-
           descend(%Ctx{sub_ctx | depth: ctx.depth + 1}, path, sha_b) do
      case diff_entries(repo, ta.entries, tb.entries, %Ctx{sub_ctx | prefix: path}) do
        {:ok, children} -> {:ok, Enum.reverse(children) ++ acc}
        {:error, _} = err -> err
      end
    end
  end

  defp expand_side(repo, path, sha, ctx, side, acc) do
    case get_tree(repo, sha) do
      {:ok, tree} ->
        case descend(ctx, path, sha) do
          {:ok, sub_ctx} ->
            case collect_side(repo, tree.entries, sub_ctx, side, acc) do
              {:ok, _} = ok -> ok
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            err
        end

      _ ->
        {:ok, [side_change(side, path, "40000", sha) | acc]}
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
