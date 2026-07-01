defmodule Exgit.RepoHandleTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, RepoHandle, Repository}

  # A small repo built in memory, used as the initial value for
  # every test's handle.
  setup do
    store = ObjectStore.Memory.new()

    {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new("hello\n"))
    tree = Tree.new([{"100644", "f.txt", blob_sha}])
    {:ok, tree_sha, store} = ObjectStore.put(store, tree)

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)

    {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
    {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = %Repository{
      object_store: store,
      ref_store: rs,
      config: Exgit.Config.new(),
      path: nil
    }

    {:ok, repo: repo}
  end

  describe "lifecycle" do
    test "start_link + fetch!", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)
      assert %Repository{} = RepoHandle.fetch!(handle)
      RepoHandle.stop(handle)
    end

    test "fetch/1 returns {:ok, repo}", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)
      assert {:ok, %Repository{}} = RepoHandle.fetch(handle)
      RepoHandle.stop(handle)
    end

    test "fetch!/1 on dead handle raises" do
      # Spawn a handle and kill it.
      {:ok, handle} =
        RepoHandle.start_link(%Repository{
          object_store: ObjectStore.Memory.new(),
          ref_store: RefStore.Memory.new(),
          config: Exgit.Config.new(),
          path: nil
        })

      RepoHandle.stop(handle)
      refute Process.alive?(handle)

      assert_raise ArgumentError, fn -> RepoHandle.fetch!(handle) end
    end

    test "fetch/1 on dead handle returns {:error, _}" do
      {:ok, handle} =
        RepoHandle.start_link(%Repository{
          object_store: ObjectStore.Memory.new(),
          ref_store: RefStore.Memory.new(),
          config: Exgit.Config.new(),
          path: nil
        })

      RepoHandle.stop(handle)
      assert {:error, _} = RepoHandle.fetch(handle)
    end

    test "named handle is accessible by name", %{repo: repo} do
      name = :"test_named_handle_#{System.unique_integer([:positive])}"
      {:ok, pid} = RepoHandle.start_link(repo, name: name)

      assert %Repository{} = RepoHandle.fetch!(name)
      assert RepoHandle.fetch!(name) == RepoHandle.fetch!(pid)

      RepoHandle.stop(name)
    end

    test "ETS table is destroyed when handle stops", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)
      table = RepoHandle.table(handle)

      # Sanity: table exists and has data.
      assert :ets.info(table) != :undefined
      assert [{:repo, _}] = :ets.lookup(table, :repo)

      RepoHandle.stop(handle)

      # The GenServer terminate/2 deletes the table; give BEAM a
      # moment to process the exit.
      :timer.sleep(10)
      assert :ets.info(table) == :undefined
    end
  end

  describe "update/2" do
    test "fun returning plain repo updates the handle", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      # Add a new blob via update.
      :ok =
        RepoHandle.update(handle, fn r ->
          {:ok, _sha, store} = ObjectStore.put(r.object_store, Blob.new("new\n"))
          %{r | object_store: store}
        end)

      new_repo = RepoHandle.fetch!(handle)
      # Store has 5 objects now (blob + tree + commit + new blob = 4, plus... wait)
      # Originally 3 objects (blob, tree, commit). After update, 4.
      assert map_size(new_repo.object_store.objects) == 4

      RepoHandle.stop(handle)
    end

    test "fun returning {:ok, repo} updates the handle", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      :ok =
        RepoHandle.update(handle, fn r ->
          {:ok, _sha, store} = ObjectStore.put(r.object_store, Blob.new("yo\n"))
          {:ok, %{r | object_store: store}}
        end)

      assert map_size(RepoHandle.fetch!(handle).object_store.objects) == 4
      RepoHandle.stop(handle)
    end

    test "fun returning {:error, _} leaves handle unchanged", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)
      snapshot_before = RepoHandle.fetch!(handle)

      result = RepoHandle.update(handle, fn _r -> {:error, :test_error} end)
      assert result == {:error, :test_error}

      assert RepoHandle.fetch!(handle) == snapshot_before
      RepoHandle.stop(handle)
    end

    test "concurrent updates are serialized", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      # Spawn N tasks, each adds one blob with a unique content.
      # With serialized updates, ALL of them should land; with
      # racy updates some would be clobbered.
      n_tasks = 20

      tasks =
        for i <- 1..n_tasks do
          Task.async(fn ->
            RepoHandle.update(handle, fn r ->
              {:ok, _sha, store} = ObjectStore.put(r.object_store, Blob.new("u#{i}\n"))
              %{r | object_store: store}
            end)
          end)
        end

      Enum.each(tasks, &Task.await/1)

      # Initial 3 (commit+tree+blob) + n new blobs.
      assert map_size(RepoHandle.fetch!(handle).object_store.objects) == 3 + n_tasks
      RepoHandle.stop(handle)
    end
  end

  describe "put/2" do
    test "replaces the stored repo value", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      # Compute a new repo outside the handle, then commit atomically.
      {:ok, _sha, store} = ObjectStore.put(repo.object_store, Blob.new("external\n"))
      new_repo = %{repo | object_store: store}

      :ok = RepoHandle.put(handle, new_repo)

      stored = RepoHandle.fetch!(handle)
      assert map_size(stored.object_store.objects) == 4
      RepoHandle.stop(handle)
    end
  end

  describe "fetch_once/4 dedup" do
    test "serializes concurrent fetches for the same key", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      # Shared counter: how many times did the fetch fn actually run?
      counter = :counters.new(1, [])

      fetch_fn = fn repo ->
        :counters.add(counter, 1, 1)
        # Simulate a slow fetch.
        Process.sleep(100)

        {:ok, _sha, new_store} =
          Exgit.ObjectStore.put(repo.object_store, Exgit.Object.Blob.new("fetched\n"))

        {:ok, %{repo | object_store: new_store}}
      end

      # 5 concurrent callers with the SAME key.
      tasks =
        for _ <- 1..5 do
          Task.async(fn -> RepoHandle.fetch_once(handle, :my_key, fetch_fn) end)
        end

      results = Task.await_many(tasks, 5_000)

      # All 5 should get the same return value.
      assert length(Enum.uniq(results)) == 1

      # But fetch_fn should have been called only ONCE.
      assert :counters.get(counter, 1) == 1

      RepoHandle.stop(handle)
    end

    test "different keys trigger independent fetches", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      counter = :counters.new(1, [])

      fetch_fn = fn repo ->
        :counters.add(counter, 1, 1)
        {:ok, repo}
      end

      # 3 different keys → 3 fetches.
      for k <- [:a, :b, :c] do
        {:ok, _} = RepoHandle.fetch_once(handle, k, fetch_fn)
      end

      assert :counters.get(counter, 1) == 3

      RepoHandle.stop(handle)
    end

    test "fetch fn returning :error propagates to all waiters", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      fetch_fn = fn _repo ->
        Process.sleep(50)
        {:error, :transport_exploded}
      end

      tasks =
        for _ <- 1..3 do
          Task.async(fn -> RepoHandle.fetch_once(handle, :err_key, fetch_fn) end)
        end

      results = Task.await_many(tasks, 2_000)

      # All 3 get the same error.
      assert Enum.all?(results, &match?({:error, :transport_exploded}, &1))

      RepoHandle.stop(handle)
    end

    test "fetch fn that exits errors promptly instead of hanging", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      # The 1s call timeout makes the test fail fast if the caller
      # would otherwise hang until the default 300s timeout.
      assert {:error, {:fetch_crashed, _}} =
               RepoHandle.fetch_once(handle, :exit_key, fn _repo -> exit(:boom) end, 1_000)

      # The in_flight entry is cleared: a subsequent fetch_once for
      # the SAME key re-runs the fetch and succeeds.
      assert {:ok, %Repository{}} =
               RepoHandle.fetch_once(handle, :exit_key, fn r -> {:ok, r} end, 1_000)

      RepoHandle.stop(handle)
    end

    test "killed fetch task errors promptly instead of hanging", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      # A brutal kill can't be caught inside the task, so this
      # exercises the monitor path: the handle sees :DOWN and
      # replies to waiters instead of leaking the in_flight entry.
      kill_fn = fn _repo -> Process.exit(self(), :kill) end

      # Reason is :killed, or :noproc when the task dies before the
      # handle's monitor attaches — both go through the :DOWN path.
      assert {:error, {:fetch_crashed, reason}} =
               RepoHandle.fetch_once(handle, :kill_key, kill_fn, 1_000)

      assert reason in [:killed, :noproc]

      # The entry is cleared: the same key fetches again and succeeds.
      assert {:ok, %Repository{}} =
               RepoHandle.fetch_once(handle, :kill_key, fn r -> {:ok, r} end, 1_000)

      RepoHandle.stop(handle)
    end

    test "handle stays responsive to reads during a slow fetch", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      slow_fetch = fn repo ->
        Process.sleep(200)
        {:ok, repo}
      end

      fetch_task =
        Task.async(fn -> RepoHandle.fetch_once(handle, :slow, slow_fetch) end)

      # While the fetch is in flight, reads should still be fast.
      :timer.sleep(20)

      start = System.monotonic_time()

      for _ <- 1..100 do
        _ = RepoHandle.fetch!(handle)
      end

      us =
        System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

      assert us < 20_000,
             "reads blocked during fetch_once (#{us}µs) — should be non-blocking"

      Task.await(fetch_task)
      RepoHandle.stop(handle)
    end
  end

  describe "read performance" do
    test "fetch!/1 does not send a message to the handle", %{repo: repo} do
      {:ok, handle} = RepoHandle.start_link(repo)

      # Capture the process's message queue length before and after
      # many fetch!/1 calls. If fetch!/1 used GenServer.call, the
      # handle would receive N :sys messages — but it's not the test
      # pid's queue that grows, it's the handle's. Instead we check
      # that fetch!/1 returns fast even while the handle is busy in
      # a slow update.
      slow_update_task =
        Task.async(fn ->
          RepoHandle.update(
            handle,
            fn r ->
              # Simulate slow work inside the handle process.
              Process.sleep(200)
              r
            end,
            5_000
          )
        end)

      # While the update is blocked, reads should still be instant.
      :timer.sleep(20)
      start = System.monotonic_time()

      for _ <- 1..100 do
        _ = RepoHandle.fetch!(handle)
      end

      reads_us =
        System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

      # 100 reads should complete in well under 10ms (typically <1ms).
      # If reads went through the GenServer they'd block behind the
      # 200ms sleep and this would be ~200ms.
      assert reads_us < 10_000,
             "100 fetch!/1 calls took #{reads_us}µs — likely blocked on GenServer, indicating a regression"

      Task.await(slow_update_task)
      RepoHandle.stop(handle)
    end
  end
end
