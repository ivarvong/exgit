defmodule Exgit.RefStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Exgit.RefStore.Memory

  @sha :crypto.hash(:sha, "test")
  @sha2 :crypto.hash(:sha, "test2")

  test "write and read" do
    store = Memory.new()
    {:ok, store} = Memory.write_ref(store, "refs/heads/main", @sha)
    assert {:ok, @sha} = Memory.read_ref(store, "refs/heads/main")
  end

  test "read returns not_found for missing ref" do
    store = Memory.new()
    assert {:error, :not_found} = Memory.read_ref(store, "refs/heads/nope")
  end

  test "symbolic refs and resolve" do
    store = Memory.new()
    {:ok, store} = Memory.write_ref(store, "refs/heads/main", @sha)
    {:ok, store} = Memory.write_ref(store, "HEAD", {:symbolic, "refs/heads/main"})

    assert {:ok, {:symbolic, "refs/heads/main"}} = Memory.read_ref(store, "HEAD")
    assert {:ok, @sha} = Memory.resolve_ref(store, "HEAD")
  end

  test "compare-and-swap" do
    store = Memory.new()
    {:ok, store} = Memory.write_ref(store, "refs/heads/main", @sha)

    assert {:error, :compare_and_swap_failed} =
             Memory.write_ref(store, "refs/heads/main", @sha2, expected: @sha2)

    assert {:ok, _store} =
             Memory.write_ref(store, "refs/heads/main", @sha2, expected: @sha)
  end

  test "delete" do
    store = Memory.new()
    {:ok, store} = Memory.write_ref(store, "refs/heads/main", @sha)
    {:ok, store} = Memory.delete_ref(store, "refs/heads/main")
    assert {:error, :not_found} = Memory.read_ref(store, "refs/heads/main")
  end

  test "list with prefix" do
    store = Memory.new()
    {:ok, store} = Memory.write_ref(store, "refs/heads/main", @sha)
    {:ok, store} = Memory.write_ref(store, "refs/heads/dev", @sha)
    {:ok, store} = Memory.write_ref(store, "refs/tags/v1", @sha)

    heads = Memory.list_refs(store, "refs/heads/")
    assert length(heads) == 2

    tags = Memory.list_refs(store, "refs/tags/")
    assert length(tags) == 1
  end
end
