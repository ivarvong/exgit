defmodule Exgit.ObjectStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore.Memory

  test "put and get" do
    store = Memory.new()
    blob = Blob.new("hello")
    {:ok, sha, store} = Memory.put_object(store, blob)

    assert {:ok, retrieved} = Memory.get_object(store, sha)
    assert retrieved.data == "hello"
  end

  test "get returns not_found for missing sha" do
    store = Memory.new()
    assert {:error, :not_found} = Memory.get_object(store, :crypto.hash(:sha, "nope"))
  end

  test "has?" do
    store = Memory.new()
    blob = Blob.new("test")
    {:ok, sha, store} = Memory.put_object(store, blob)

    assert Memory.has_object?(store, sha)
    refute Memory.has_object?(store, :crypto.hash(:sha, "other"))
  end

  test "delete_object removes the object AND its size index entry" do
    store = Memory.new()
    {:ok, sha, store} = Memory.put_object(store, Blob.new("hello"))
    assert {:ok, 5} = Memory.object_size(store, sha)

    assert {:ok, freed, store} = Memory.delete_object(store, sha)
    assert freed > 0

    refute Memory.has_object?(store, sha)
    assert {:error, :not_found} = Memory.get_object(store, sha)
    # The sizes index must be kept in lockstep — no stale size for a
    # deleted object.
    assert {:error, :not_found} = Memory.object_size(store, sha)
  end

  test "delete_object returns not_found for a missing sha" do
    assert {:error, :not_found} =
             Memory.delete_object(Memory.new(), :crypto.hash(:sha, "nope"))
  end

  test "import_objects" do
    content = "imported"
    sha = Exgit.Object.sha(Blob.new(content))
    {:ok, store} = Memory.import_objects(Memory.new(), [{:blob, sha, content}])

    assert Memory.has_object?(store, sha)
    assert {:ok, %Blob{data: "imported"}} = Memory.get_object(store, sha)
  end
end
