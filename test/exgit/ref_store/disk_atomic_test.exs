defmodule Exgit.RefStore.DiskAtomicTest do
  use ExUnit.Case, async: true

  alias Exgit.RefStore.Disk

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "exgit_refstore_disk_atomic_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "refs/heads"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: Disk.new(root)}
  end

  describe "atomic ref writes (P0.2)" do
    test "write is durable via tmp+rename (no half-written file visible)", %{
      root: root,
      store: store
    } do
      sha = :binary.copy(<<1>>, 20)

      :ok = Disk.write_ref(store, "refs/heads/main", sha, [])

      # The final file must contain exactly the hex sha + newline. No
      # partial writes, no temp-file leakage in the visible ref path.
      path = Path.join(root, "refs/heads/main")
      assert File.read!(path) == Base.encode16(sha, case: :lower) <> "\n"

      # No stray .lock files should remain after a successful write.
      dir = Path.join(root, "refs/heads")

      stray_locks =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".lock"))

      assert stray_locks == [], "leftover lock files: #{inspect(stray_locks)}"
    end

    test "concurrent CAS: only one writer wins, the other gets :compare_and_swap_failed", %{
      store: store
    } do
      old = :binary.copy(<<1>>, 20)
      a = :binary.copy(<<2>>, 20)
      b = :binary.copy(<<3>>, 20)

      :ok = Disk.write_ref(store, "refs/heads/main", old, [])

      parent = self()

      spawn_link(fn ->
        send(parent, {:a, Disk.write_ref(store, "refs/heads/main", a, expected: old)})
      end)

      spawn_link(fn ->
        send(parent, {:b, Disk.write_ref(store, "refs/heads/main", b, expected: old)})
      end)

      results =
        for _ <- 1..2 do
          receive do
            {_, r} -> r
          after
            5_000 -> flunk("concurrent writers did not report in time")
          end
        end

      # Exactly one success. The other must fail with either:
      #   - :compare_and_swap_failed (expected mismatched at write time), or
      #   - :ref_locked (lost the race to acquire the lock file).
      # Both are acceptable CAS failure modes; what MUST NOT happen is
      # both writes succeeding.
      successes = Enum.count(results, &(&1 == :ok))

      failures =
        Enum.count(results, fn
          {:error, :compare_and_swap_failed} -> true
          {:error, :ref_locked} -> true
          _ -> false
        end)

      assert successes == 1, "expected exactly one success, got results=#{inspect(results)}"

      assert failures == 1,
             "expected exactly one CAS/lock failure, got results=#{inspect(results)}"

      # The ref must hold exactly one of the candidate values, never a mix.
      {:ok, final} = Disk.read_ref(store, "refs/heads/main")
      assert final in [a, b]
    end

    test "CAS refuses when expected does not match current", %{store: store} do
      current = :binary.copy(<<1>>, 20)
      other = :binary.copy(<<9>>, 20)
      new = :binary.copy(<<2>>, 20)

      :ok = Disk.write_ref(store, "refs/heads/main", current, [])

      assert {:error, :compare_and_swap_failed} =
               Disk.write_ref(store, "refs/heads/main", new, expected: other)

      # Value must be unchanged.
      {:ok, v} = Disk.read_ref(store, "refs/heads/main")
      assert v == current
    end

    test "CAS with matching expected succeeds", %{store: store} do
      current = :binary.copy(<<1>>, 20)
      new = :binary.copy(<<2>>, 20)

      :ok = Disk.write_ref(store, "refs/heads/main", current, [])

      assert :ok = Disk.write_ref(store, "refs/heads/main", new, expected: current)
      assert {:ok, v} = Disk.read_ref(store, "refs/heads/main")
      assert v == new
    end
  end
end
