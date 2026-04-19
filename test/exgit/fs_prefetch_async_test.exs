defmodule Exgit.FSPrefetchAsyncTest do
  use ExUnit.Case, async: true

  alias Exgit.{FS, ObjectStore, RefStore, RepoHandle, Repository}
  alias Exgit.Object.{Blob, Commit, Tree}

  # Memory-backed repo. `FS.prefetch/3` on a non-Promisor store is a
  # no-op, so these tests exercise the ASYNC plumbing + handle
  # integration, not the network path. A separate :network-tagged
  # test exercises the real fetch.
  setup do
    store = ObjectStore.Memory.new()

    {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new("hi\n"))
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

    {:ok, handle} = RepoHandle.start_link(repo)
    on_exit(fn -> if Process.alive?(handle), do: RepoHandle.stop(handle) end)

    {:ok, repo: repo, handle: handle}
  end

  describe "prefetch_async/2" do
    test "returns a Task immediately", %{handle: handle} do
      {:ok, task} = FS.prefetch_async(handle)
      assert %Task{} = task
      # Let the task finish so on_exit cleanup is clean.
      {:ok, :prefetched} = FS.await_prefetch(task)
    end

    test "completes successfully on a Memory-backed handle", %{handle: handle} do
      {:ok, task} = FS.prefetch_async(handle)
      assert {:ok, :prefetched} = FS.await_prefetch(task)
    end

    test "handle is updated after task completes", %{handle: handle} do
      before = RepoHandle.get(handle)
      {:ok, task} = FS.prefetch_async(handle)
      {:ok, :prefetched} = FS.await_prefetch(task)
      after_ = RepoHandle.get(handle)

      # For Memory-backed store, the update is a no-op but the
      # call still runs (which is what we're testing — the task
      # ran through to completion without crashing).
      assert before.object_store == after_.object_store
    end

    test "async prefetch does not block foreground reads", %{handle: handle} do
      # Start an async prefetch and immediately do many reads.
      # The reads should complete before the prefetch (both are
      # fast for Memory, but the invariant is: reads don't block
      # on the task).
      {:ok, task} = FS.prefetch_async(handle)

      # 100 reads while the task is (was) running.
      for _ <- 1..100 do
        assert %Repository{} = RepoHandle.get(handle)
      end

      {:ok, :prefetched} = FS.await_prefetch(task)
    end

    test "concurrent async prefetches are all serialized safely", %{handle: handle} do
      # Spawn 5 prefetch_async tasks. The handle's update/2
      # serializes them; each sees a consistent repo snapshot.
      tasks =
        for _ <- 1..5 do
          {:ok, task} = FS.prefetch_async(handle)
          task
        end

      for task <- tasks do
        assert {:ok, :prefetched} = FS.await_prefetch(task)
      end
    end

    test "prefetch_async on a dead handle returns error" do
      # Start and immediately stop a handle.
      {:ok, dead_handle} =
        RepoHandle.start_link(%Repository{
          object_store: ObjectStore.Memory.new(),
          ref_store: RefStore.Memory.new(),
          config: Exgit.Config.new(),
          path: nil
        })

      RepoHandle.stop(dead_handle)

      assert {:error, _} = FS.prefetch_async(dead_handle)
    end
  end

  describe "await_prefetch/2" do
    test "returns {:error, :timeout} if task doesn't finish", %{handle: handle} do
      # Force a long-running update by using a custom task that
      # we control. We can't easily inject slowness into the real
      # prefetch on Memory, so we verify the timeout semantics
      # on a synthetic Task instead.
      task =
        Task.Supervisor.async_nolink(Exgit.TaskSupervisor, fn ->
          Process.sleep(500)
          {:ok, :prefetched}
        end)

      assert {:error, :timeout} = FS.await_prefetch(task, 50)

      # Clean up.
      Task.shutdown(task, :brutal_kill)
      _ = handle
    end
  end

  describe "cancel_prefetch/1" do
    test "shuts down a running task", %{handle: handle} do
      # Launch a long-running synthetic task via the supervisor
      # and cancel it. The normal prefetch_async on Memory is too
      # fast to cancel mid-flight reliably.
      task =
        Task.Supervisor.async_nolink(Exgit.TaskSupervisor, fn ->
          Process.sleep(10_000)
          {:ok, :prefetched}
        end)

      assert :ok = FS.cancel_prefetch(task)

      # Task should be dead now.
      :timer.sleep(10)
      refute Process.alive?(task.pid)

      _ = handle
    end

    test "cancel emits telemetry" do
      test_pid = self()

      handler_id = "cancel-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:exgit, :fs, :prefetch_async, :cancelled],
        fn _event, _m, md, _ -> send(test_pid, {:cancelled, md}) end,
        nil
      )

      try do
        task =
          Task.Supervisor.async_nolink(Exgit.TaskSupervisor, fn ->
            Process.sleep(10_000)
          end)

        FS.cancel_prefetch(task)

        assert_receive {:cancelled, _}, 500
      after
        :telemetry.detach(handler_id)
      end
    end

    test "cancel on already-completed task is idempotent", %{handle: handle} do
      {:ok, task} = FS.prefetch_async(handle)
      {:ok, :prefetched} = FS.await_prefetch(task)

      # Cancelling a completed task should not crash.
      assert :ok = FS.cancel_prefetch(task)
    end
  end
end
