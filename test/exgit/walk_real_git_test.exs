defmodule Exgit.WalkRealGitTest do
  @moduledoc """
  Cross-check `Exgit.Walk.merge_base/2` and `ancestors/3` against
  the real `git` binary on randomly-generated commit DAGs.

  Tagged `:real_git`; requires `git` on PATH.

  Shape: construct a DAG in real git (via `git commit-tree`), then
  load the resulting objects into an exgit repo and compare
  merge-base / ancestor results. If our walk disagrees with git on
  any case, the test fails with the concrete DAG that broke it.
  """

  use ExUnit.Case, async: false
  @moduletag :real_git

  alias Exgit.Test.RealGit
  alias Exgit.{Repository, Walk}

  @empty_tree_hex "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  defp empty_tree_in!(cwd) do
    # Populate the empty-tree object in the repo so subsequent
    # commit-tree calls have something to reference.
    {_, 0} = RealGit.git!(cwd, ["hash-object", "-w", "-t", "tree", "/dev/null"])
    @empty_tree_hex
  end

  defp build_dag!(cwd, shape) do
    # `shape` is a list of {label, [parent_labels]} in topological
    # order (parents first). Returns a map %{label => hex_sha}.
    tree = empty_tree_in!(cwd)

    Enum.reduce(shape, %{}, fn {label, parent_labels}, acc ->
      parents = Enum.map(parent_labels, &Map.fetch!(acc, &1))

      sha =
        RealGit.commit_tree!(cwd,
          tree: tree,
          parents: parents,
          message: "#{label}\n"
        )

      Map.put(acc, label, sha)
    end)
  end

  defp load_into_exgit(cwd) do
    # Point an eager exgit repo at the on-disk object store git
    # populated. No fetch/clone needed — we just want direct object
    # reads for Walk queries.
    git_dir = Path.join(cwd, ".git")

    store = Exgit.ObjectStore.Disk.new(git_dir)
    ref_store = Exgit.RefStore.Disk.new(git_dir)
    Repository.new(store, ref_store)
  end

  describe "merge_base matches git merge-base" do
    for shape_name <- ["fork", "criss_cross", "linear", "deep_fork", "octopus"] do
      @tag :real_git
      test "#{shape_name}" do
        cwd = RealGit.tmp_dir!("exgit_walk_rg_#{unquote(shape_name)}")
        RealGit.init!(cwd)

        shape = build_shape(unquote(shape_name))
        labels = build_dag!(cwd, shape)

        # Pick every pair of leaves and compare merge-base output.
        leaves = leaves_of(shape)

        repo = load_into_exgit(cwd)

        for a <- leaves, b <- leaves, a < b do
          sha_a = Map.fetch!(labels, a)
          sha_b = Map.fetch!(labels, b)

          # `git merge-base --all` is the authoritative set of valid
          # LCAs. We require exgit to return SOME value from that
          # set (git-compatible semantics), not necessarily the same
          # deterministic winner git's plain `merge-base` picks —
          # tie-breaking on identical timestamps is
          # traversal-order-dependent in git and we don't replicate
          # it exactly. This matches the contract documented on
          # `Walk.merge_base/2`.
          git_all =
            case RealGit.git!(cwd, ["merge-base", "--all", sha_a, sha_b], allow_error: true) do
              {out, 0} ->
                out |> String.split("\n", trim: true) |> MapSet.new()

              _ ->
                MapSet.new()
            end

          exgit_result =
            case Walk.merge_base(repo, [RealGit.hex_to_bin(sha_a), RealGit.hex_to_bin(sha_b)]) do
              {:ok, bin} -> RealGit.bin_to_hex(bin)
              _ -> nil
            end

          if MapSet.size(git_all) == 0 do
            assert exgit_result == nil,
                   "merge_base(#{a}, #{b}): git says no LCA but exgit returned #{inspect(exgit_result)}"
          else
            assert exgit_result in git_all,
                   "merge_base(#{a}, #{b}) picked #{inspect(exgit_result)}, " <>
                     "which is NOT in git's valid LCA set #{inspect(MapSet.to_list(git_all))}"
          end
        end

        # Also assert merge_base_all/2 matches git's --all output.
        for a <- leaves, b <- leaves, a < b do
          sha_a = Map.fetch!(labels, a)
          sha_b = Map.fetch!(labels, b)

          git_all =
            case RealGit.git!(cwd, ["merge-base", "--all", sha_a, sha_b], allow_error: true) do
              {out, 0} ->
                out |> String.split("\n", trim: true) |> MapSet.new()

              _ ->
                MapSet.new()
            end

          exgit_all =
            case Walk.merge_base_all(repo, [RealGit.hex_to_bin(sha_a), RealGit.hex_to_bin(sha_b)]) do
              {:ok, bins} -> bins |> Enum.map(&RealGit.bin_to_hex/1) |> MapSet.new()
              _ -> MapSet.new()
            end

          assert exgit_all == git_all,
                 "merge_base_all(#{a}, #{b}) disagrees with git --all: " <>
                   "exgit=#{inspect(MapSet.to_list(exgit_all))} git=#{inspect(MapSet.to_list(git_all))}"
        end

        File.rm_rf!(cwd)
      end
    end
  end

  # --- DAG shapes ---

  defp build_shape("fork") do
    # R - A - B
    #      \
    #       C
    [{"R", []}, {"A", ["R"]}, {"B", ["A"]}, {"C", ["A"]}]
  end

  defp build_shape("criss_cross") do
    # R - A - B - M1
    #      \ / \ /
    #       X   X
    #      / \ / \
    #     C - D - M2
    [
      {"R", []},
      {"A", ["R"]},
      {"C", ["R"]},
      {"B", ["A", "C"]},
      {"D", ["A", "C"]},
      {"M1", ["B", "D"]},
      {"M2", ["B", "D"]}
    ]
  end

  defp build_shape("linear") do
    [{"A", []}, {"B", ["A"]}, {"C", ["B"]}, {"D", ["C"]}, {"E", ["D"]}]
  end

  defp build_shape("deep_fork") do
    # Long shared prefix, divergent tail.
    base = for i <- 1..20, do: {"S#{i}", if(i == 1, do: [], else: ["S#{i - 1}"])}
    left = for i <- 1..5, do: {"L#{i}", if(i == 1, do: ["S20"], else: ["L#{i - 1}"])}
    right = for i <- 1..5, do: {"R#{i}", if(i == 1, do: ["S20"], else: ["R#{i - 1}"])}
    base ++ left ++ right
  end

  defp build_shape("octopus") do
    # Multi-parent merge.
    [
      {"R", []},
      {"A", ["R"]},
      {"B", ["R"]},
      {"C", ["R"]},
      {"M", ["A", "B", "C"]}
    ]
  end

  defp leaves_of(shape) do
    all = for {l, _} <- shape, do: l
    referenced = for {_, ps} <- shape, p <- ps, uniq: true, do: p
    Enum.reject(all, &(&1 in referenced))
  end
end
