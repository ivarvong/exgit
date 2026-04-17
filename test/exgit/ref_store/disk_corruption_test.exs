defmodule Exgit.RefStore.DiskCorruptionTest do
  use ExUnit.Case, async: true

  alias Exgit.RefStore.Disk

  setup do
    root =
      Path.join(System.tmp_dir!(), "exgit_refstore_corrupt_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "refs/heads"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: Disk.new(root)}
  end

  describe "corrupt refs do not crash (P1.3)" do
    test "garbage bytes in a ref file return {:error, _}", %{root: root, store: store} do
      path = Path.join(root, "refs/heads/weird")
      File.write!(path, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n")

      assert {:error, _} = Disk.read_ref(store, "refs/heads/weird")
    end

    test "truncated (too-short) ref content returns {:error, _}", %{root: root, store: store} do
      path = Path.join(root, "refs/heads/trunc")
      File.write!(path, "abcd\n")

      assert {:error, _} = Disk.read_ref(store, "refs/heads/trunc")
    end

    test "empty ref file returns {:error, _}", %{root: root, store: store} do
      path = Path.join(root, "refs/heads/empty")
      File.write!(path, "")

      assert {:error, _} = Disk.read_ref(store, "refs/heads/empty")
    end

    test "random bytes of any length do not raise", %{root: root, store: store} do
      # Fuzz: write a bunch of different random contents and ensure we
      # always return a structured result.
      for size <- [0, 1, 5, 20, 39, 40, 41, 100] do
        path = Path.join(root, "refs/heads/fuzz_#{size}")
        File.write!(path, :crypto.strong_rand_bytes(size))

        result =
          try do
            Disk.read_ref(store, "refs/heads/fuzz_#{size}")
          rescue
            e -> {:raised, e}
          end

        refute match?({:raised, _}, result),
               "read_ref raised on #{size}-byte garbage: #{inspect(result)}"
      end
    end
  end
end
