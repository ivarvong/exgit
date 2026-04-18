defmodule Exgit.DiffModesTest do
  use ExUnit.Case, async: true

  alias Exgit.Diff
  alias Exgit.Object.{Blob, Tree}
  alias Exgit.ObjectStore

  setup do
    %{store: ObjectStore.Memory.new()}
  end

  describe "mode information in diff tuples (P3.6)" do
    test "mode-only change (chmod +x) reports both old and new modes", %{store: store} do
      blob = Blob.new("#!/bin/sh\necho hi\n")
      {:ok, blob_sha, store} = ObjectStore.put(store, blob)

      tree_a = Tree.new([{"100644", "run", blob_sha}])
      tree_b = Tree.new([{"100755", "run", blob_sha}])

      {:ok, a_sha, store} = ObjectStore.put(store, tree_a)
      {:ok, b_sha, store} = ObjectStore.put(store, tree_b)

      repo = %{object_store: store}

      {:ok, changes} = Diff.trees(repo, a_sha, b_sha)

      assert [change] = changes

      # Contract: diff tuples expose mode info so callers can distinguish
      # "content changed" from "only mode changed". The new shape is a
      # map with explicit fields (backwards-compatible aliases may exist).
      assert %{
               op: :mode_changed,
               path: "run",
               old_mode: "100644",
               new_mode: "100755",
               old_sha: ^blob_sha,
               new_sha: ^blob_sha
             } = change
    end

    test "submodule (gitlink 160000) change reports :submodule_change, not :modified", %{
      store: store
    } do
      a_target = :binary.copy(<<1>>, 20)
      b_target = :binary.copy(<<2>>, 20)

      # Real git trees never contain `/` in entry names — a nested
      # submodule path is a tree-of-trees-of-gitlinks. Build the
      # canonical shape so `Tree.decode/1`'s tree-entry-name
      # validation (which rejects `/` for path-traversal reasons)
      # is satisfied.
      inner_a = Tree.new([{"160000", "lib", a_target}])
      inner_b = Tree.new([{"160000", "lib", b_target}])
      {:ok, inner_a_sha, store} = ObjectStore.put(store, inner_a)
      {:ok, inner_b_sha, store} = ObjectStore.put(store, inner_b)

      tree_a = Tree.new([{"40000", "vendor", inner_a_sha}])
      tree_b = Tree.new([{"40000", "vendor", inner_b_sha}])

      {:ok, a_sha, store} = ObjectStore.put(store, tree_a)
      {:ok, b_sha, store} = ObjectStore.put(store, tree_b)

      repo = %{object_store: store}

      {:ok, [change]} = Diff.trees(repo, a_sha, b_sha)

      assert %{
               op: :submodule_change,
               path: "vendor/lib",
               old_sha: ^a_target,
               new_sha: ^b_target
             } = change
    end

    test "content change produces :modified with both modes present", %{store: store} do
      a = Blob.new("one\n")
      b = Blob.new("two\n")
      {:ok, a_sha, store} = ObjectStore.put(store, a)
      {:ok, b_sha, store} = ObjectStore.put(store, b)

      tree_a = Tree.new([{"100644", "f", a_sha}])
      tree_b = Tree.new([{"100644", "f", b_sha}])

      {:ok, ta_sha, store} = ObjectStore.put(store, tree_a)
      {:ok, tb_sha, store} = ObjectStore.put(store, tree_b)

      repo = %{object_store: store}
      {:ok, [change]} = Diff.trees(repo, ta_sha, tb_sha)

      assert %{
               op: :modified,
               path: "f",
               old_mode: "100644",
               new_mode: "100644",
               old_sha: ^a_sha,
               new_sha: ^b_sha
             } = change
    end
  end
end
