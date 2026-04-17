defmodule Exgit.StoreSemanticsTest do
  @moduledoc """
  Contract tests that both the Memory and Disk store implementations
  must pass. These pin the shared semantics so that callers can
  interchange them.
  """
  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore

  describe "ObjectStore contract — Memory (P1.4)" do
    setup do
      %{store: ObjectStore.Memory.new()}
    end

    test "put returns {:ok, sha, updated_store}", %{store: store} do
      blob = Blob.new("hi\n")
      assert {:ok, sha, store2} = ObjectStore.put(store, blob)
      assert byte_size(sha) == 20
      assert store != store2
    end

    test "get after put returns the same blob", %{store: store} do
      blob = Blob.new("data\n")
      {:ok, sha, store} = ObjectStore.put(store, blob)
      assert {:ok, ^blob} = ObjectStore.get(store, sha)
    end

    test "get on missing sha returns :not_found", %{store: store} do
      assert {:error, :not_found} = ObjectStore.get(store, :binary.copy(<<0>>, 20))
    end

    test "has? reflects presence", %{store: store} do
      blob = Blob.new("xyz")
      sha = Blob.sha(blob)
      refute ObjectStore.has?(store, sha)

      {:ok, _, store} = ObjectStore.put(store, blob)
      assert ObjectStore.has?(store, sha)
    end
  end

  describe "ObjectStore contract — Disk" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "exgit_store_contract_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "objects"))
      on_exit(fn -> File.rm_rf!(root) end)
      %{store: ObjectStore.Disk.new(root)}
    end

    test "put returns {:ok, sha, store}; the returned store is functionally equivalent", %{
      store: store
    } do
      blob = Blob.new("hi\n")
      assert {:ok, sha, store2} = ObjectStore.put(store, blob)
      assert byte_size(sha) == 20

      # Disk's state lives on the filesystem; the returned struct may be
      # identical to the input. Either way, both must be able to read
      # the newly-put object.
      assert {:ok, ^blob} = ObjectStore.get(store, sha)
      assert {:ok, ^blob} = ObjectStore.get(store2, sha)
    end

    test "get on missing sha returns :not_found", %{store: store} do
      assert {:error, :not_found} = ObjectStore.get(store, :binary.copy(<<0>>, 20))
    end

    test "has? reflects presence", %{store: store} do
      blob = Blob.new("xyz")
      sha = Blob.sha(blob)
      refute ObjectStore.has?(store, sha)

      {:ok, _, store} = ObjectStore.put(store, blob)
      assert ObjectStore.has?(store, sha)
    end
  end

  describe "RefStore contract — Memory vs Disk" do
    test "write then read returns the same value (Memory)" do
      store = Exgit.RefStore.Memory.new()
      sha = :binary.copy(<<7>>, 20)

      assert {:ok, store} = Exgit.RefStore.write(store, "refs/heads/a", sha, [])
      assert {:ok, ^sha} = Exgit.RefStore.read(store, "refs/heads/a")
    end

    test "write then read returns the same value (Disk)" do
      root =
        Path.join(System.tmp_dir!(), "exgit_ref_contract_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "refs/heads"))

      try do
        store = Exgit.RefStore.Disk.new(root)
        sha = :binary.copy(<<7>>, 20)

        assert {:ok, store} = Exgit.RefStore.write(store, "refs/heads/a", sha, [])
        assert {:ok, ^sha} = Exgit.RefStore.read(store, "refs/heads/a")
      after
        File.rm_rf!(root)
      end
    end
  end
end
