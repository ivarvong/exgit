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

  test "import_objects" do
    content = "imported"
    sha = Exgit.Object.sha(Blob.new(content))
    {:ok, store} = Memory.import_objects(Memory.new(), [{:blob, sha, content}])

    assert Memory.has_object?(store, sha)
    assert {:ok, %Blob{data: "imported"}} = Memory.get_object(store, sha)
  end
end
