defmodule Exgit.RefStore.CycleTest do
  use ExUnit.Case, async: true

  alias Exgit.RefStore

  describe "cycle detection (P3.3)" do
    test "self-referential symbolic ref returns {:error, :cycle}" do
      store = RefStore.Memory.new()
      {:ok, store} = RefStore.write(store, "HEAD", {:symbolic, "HEAD"}, [])

      assert {:error, :cycle} = RefStore.resolve(store, "HEAD")
    end

    test "longer cycle a -> b -> a returns {:error, :cycle}" do
      store = RefStore.Memory.new()
      {:ok, store} = RefStore.write(store, "a", {:symbolic, "b"}, [])
      {:ok, store} = RefStore.write(store, "b", {:symbolic, "a"}, [])

      assert {:error, :cycle} = RefStore.resolve(store, "a")
    end

    test "Disk: self-referential symbolic ref returns {:error, :cycle}" do
      root = Path.join(System.tmp_dir!(), "exgit_cycle_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "refs"))
      store = RefStore.Disk.new(root)

      try do
        {:ok, _} = RefStore.write(store, "HEAD", {:symbolic, "HEAD"}, [])
        assert {:error, :cycle} = RefStore.resolve(store, "HEAD")
      after
        File.rm_rf!(root)
      end
    end
  end
end
