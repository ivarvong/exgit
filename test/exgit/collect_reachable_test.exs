defmodule Exgit.CollectReachableTest do
  @moduledoc """
  Tests for `Exgit.collect_reachable/3` semantics surfaced via push.

  The function is private, so we exercise it through the push pipeline:
    - build a repo with a graph of commits,
    - push to a file transport with a receiving bare repo,
    - assert the set of objects that end up in the receiving repo equals
      exactly the set of reachable objects from the pushed ref, with no
      duplicate work.
  """
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore
  alias Exgit.Test.CommitGraph

  describe "reachability traversal (P0.16)" do
    test "push produces a pack of exactly the reachable objects (no duplicates)" do
      # Build a diamond graph where both branches share the same blob. A
      # buggy reachability walk that doesn't properly thread `seen` will
      # emit duplicate objects in the pack; the pack reader will then see
      # N_full > N_distinct.
      graph = %{
        "R" => [],
        "L" => ["R"],
        "Rt" => ["R"],
        "M" => ["L", "Rt"]
      }

      {repo, shas} = CommitGraph.build(graph)

      # Set HEAD to M.
      %{object_store: store} = repo
      {:ok, ref_store} = Exgit.RefStore.write(Exgit.RefStore.Memory.new(), "HEAD", shas["M"], [])

      repo = %Exgit.Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      # Push to an on-disk bare repo via the File transport.
      dest =
        Path.join(System.tmp_dir!(), "exgit_push_diamond_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dest, "refs/heads"))
      File.mkdir_p!(Path.join(dest, "objects"))
      File.write!(Path.join(dest, "HEAD"), "ref: refs/heads/main\n")

      transport = Exgit.Transport.File.new(dest)

      # Use refspec HEAD so collect_push_objects walks from M.
      # The File transport uses "refs/heads/main" — adjust refspec.
      {:ok, _} =
        Exgit.RefStore.write(repo.ref_store, "refs/heads/main", shas["M"], [])

      updated_ref_store =
        case Exgit.RefStore.write(repo.ref_store, "refs/heads/main", shas["M"], []) do
          {:ok, rs} -> rs
          _ -> repo.ref_store
        end

      repo = %{repo | ref_store: updated_ref_store}

      {:ok, _result} =
        Exgit.push(repo, transport, refspecs: ["refs/heads/main"])

      # Count distinct objects that ended up on disk.
      disk_store = Exgit.ObjectStore.Disk.new(dest)
      objects = Exgit.ObjectStore.Disk.list_objects(disk_store)

      expected = count_reachable(repo, shas["M"])

      # Objects on disk must equal the reachable count — not more (that
      # would indicate duplicates in the pack) and not less (missing
      # reachable data).
      assert length(objects) == expected,
             "disk has #{length(objects)} objects, reachable=#{expected}"

      File.rm_rf!(dest)
    end

    test "handles deep linear chains without stack overflow" do
      # Build a chain of 2000 commits. An unbounded-recursion implementation
      # of collect_reachable would blow the BEAM process stack.
      n = 2_000

      graph =
        for i <- 0..(n - 1), into: %{} do
          parent = if i == 0, do: [], else: ["n#{i - 1}"]
          {"n#{i}", parent}
        end

      {repo, shas} = CommitGraph.build(graph)

      # Walk all ancestors via the public API (also stresses traversal).
      count =
        Exgit.Walk.ancestors(repo, shas["n#{n - 1}"])
        |> Enum.count()

      assert count == n
    end

    @tag :slow
    test "push of a very deep chain does not stack-overflow collect_reachable" do
      # collect_reachable in lib/exgit.ex was non-tail-recursive, so
      # deep chains could blow the stack. Reproduce via push end-to-end.
      n = 5_000

      graph =
        for i <- 0..(n - 1), into: %{} do
          parent = if i == 0, do: [], else: ["n#{i - 1}"]
          {"n#{i}", parent}
        end

      {repo, shas} = CommitGraph.build(graph)

      %{object_store: store} = repo

      {:ok, ref_store} =
        Exgit.RefStore.write(
          Exgit.RefStore.Memory.new(),
          "refs/heads/main",
          shas["n#{n - 1}"],
          []
        )

      repo = %Exgit.Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      dest =
        Path.join(System.tmp_dir!(), "exgit_push_chain_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dest, "refs/heads"))
      File.mkdir_p!(Path.join(dest, "objects"))
      File.write!(Path.join(dest, "HEAD"), "ref: refs/heads/main\n")

      transport = Exgit.Transport.File.new(dest)

      assert {:ok, _} =
               Exgit.push(repo, transport, refspecs: ["refs/heads/main"])

      File.rm_rf!(dest)
    end
  end

  # Count distinct reachable objects via a hand-rolled traversal.
  defp count_reachable(repo, start_sha) do
    count_reachable(repo, [start_sha], MapSet.new(), 0)
  end

  defp count_reachable(_repo, [], _seen, count), do: count

  defp count_reachable(repo, [sha | rest], seen, count) do
    if MapSet.member?(seen, sha) do
      count_reachable(repo, rest, seen, count)
    else
      seen = MapSet.put(seen, sha)

      case ObjectStore.get(repo.object_store, sha) do
        {:ok, obj} ->
          children = object_children(obj)
          count_reachable(repo, children ++ rest, seen, count + 1)

        _ ->
          count_reachable(repo, rest, seen, count)
      end
    end
  end

  defp object_children(%Commit{} = c),
    do: [Commit.tree(c) | Commit.parents(c)]

  defp object_children(%Tree{entries: entries}),
    do: Enum.map(entries, &elem(&1, 2))

  defp object_children(%Blob{}), do: []
end
