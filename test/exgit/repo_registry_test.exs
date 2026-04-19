defmodule Exgit.RepoRegistryTest do
  # async: false because the registry is a singleton (named
  # module-global GenServer) — multiple tests running in parallel
  # would stomp each other's state.
  use ExUnit.Case, async: false

  alias Exgit.{RepoHandle, RepoRegistry}

  # Stub the clone function so we don't need network for registry
  # mechanics tests. The real-network get_or_start is tested
  # separately under :network.
  defmodule FakeTransport do
    defmodule Clone do
      def build_fake_repo do
        alias Exgit.Object.{Blob, Commit, Tree}
        alias Exgit.{ObjectStore, RefStore}

        store = ObjectStore.Memory.new()
        {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new("x\n"))
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

        {:ok, rs} =
          RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

        {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

        %Exgit.Repository{
          object_store: store,
          ref_store: rs,
          config: Exgit.Config.new(),
          path: nil
        }
      end
    end
  end

  setup do
    # Ensure a clean registry per test. Because the registry is a
    # named singleton, any leftover state from a previous test would
    # leak.  First stop anything stale, then start fresh.
    cleanup_registry()
    {:ok, _pid} = RepoRegistry.start_link()

    on_exit(&cleanup_registry/0)

    :ok
  end

  defp cleanup_registry do
    case Process.whereis(RepoRegistry) do
      nil ->
        :ok

      pid ->
        # Stop all URLs first.
        for url <- RepoRegistry.list() do
          RepoRegistry.stop(url)
        end

        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 2000)
          catch
            :exit, _ -> :ok
          end
        end

        # Wait for the name to become free before returning.
        wait_for_unregister(RepoRegistry, 500)
    end
  end

  defp wait_for_unregister(_name, 0), do: :ok

  defp wait_for_unregister(name, retries) do
    case Process.whereis(name) do
      nil ->
        :ok

      _pid ->
        Process.sleep(5)
        wait_for_unregister(name, retries - 1)
    end
  end

  describe "lookup + stop" do
    test "lookup returns :error when URL is not registered" do
      assert :error = RepoRegistry.lookup("https://example.com/not-registered")
    end

    test "stop on unregistered URL is :ok" do
      assert :ok = RepoRegistry.stop("https://example.com/not-registered")
    end

    test "count is 0 when nothing is registered" do
      assert 0 == RepoRegistry.count()
    end

    test "list is [] when nothing is registered" do
      assert [] == RepoRegistry.list()
    end
  end

  describe "handle_call without running registry" do
    test "get_or_start returns :not_started when registry isn't running" do
      # Stop the registry first (setup started it; we force-stop
      # here to simulate the unstarted case).
      ref = Process.monitor(RepoRegistry)
      GenServer.stop(RepoRegistry)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        1000 -> flunk("registry didn't stop")
      end

      assert {:error, :not_started} =
               RepoRegistry.get_or_start("https://example.com/whatever")
    end

    test "lookup returns :error when registry isn't running" do
      ref = Process.monitor(RepoRegistry)
      GenServer.stop(RepoRegistry)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        1000 -> flunk("registry didn't stop")
      end

      assert :error = RepoRegistry.lookup("https://example.com/whatever")
    end
  end

  describe "manual handle registration (simulating a successful clone)" do
    # We can't easily mock the private clone_for_registry/2 without a
    # module-attribute swap or a dependency-inversion refactor. Instead,
    # verify the BEHAVIOR we care about — concurrent get_or_start
    # serializes, stop/1 cleans up — by registering a handle directly
    # via RepoHandle.start_link with a :via name, bypassing the clone
    # step of get_or_start.
    test "handle registered via :via name is discoverable via lookup" do
      repo = FakeTransport.Clone.build_fake_repo()
      url = "fake://test-handle-lookup"

      via = {:via, Registry, {Exgit.RepoRegistry.Registry, url}}
      {:ok, handle} = RepoHandle.start_link(repo, name: via)

      assert {:ok, ^handle} = RepoRegistry.lookup(url)

      # Can fetch through the handle.
      assert %Exgit.Repository{} = RepoHandle.get(handle)

      RepoHandle.stop(handle)
    end

    @tag :network
    @tag :integration
    test "real get_or_start clones and shares handle across callers" do
      # Verifies END-TO-END: two concurrent get_or_start calls
      # for the same URL produce ONE clone and ONE shared handle.
      url = "https://github.com/anthropics/claude-agent-sdk-python"

      # Two concurrent callers.
      tasks =
        for _ <- 1..3 do
          Task.async(fn -> RepoRegistry.get_or_start(url) end)
        end

      results = Enum.map(tasks, &Task.await(&1, 30_000))

      # All three got the same handle.
      assert Enum.uniq(results) |> length() == 1
      {:ok, handle} = hd(results)
      assert is_pid(handle)
      assert Process.alive?(handle)

      # Only one URL registered.
      assert 1 == RepoRegistry.count()

      RepoRegistry.stop(url)
    end

    test "count and list reflect registered handles" do
      repo = FakeTransport.Clone.build_fake_repo()
      url1 = "fake://count-test-1"
      url2 = "fake://count-test-2"

      via1 = {:via, Registry, {Exgit.RepoRegistry.Registry, url1}}
      via2 = {:via, Registry, {Exgit.RepoRegistry.Registry, url2}}

      {:ok, h1} = RepoHandle.start_link(repo, name: via1)
      {:ok, h2} = RepoHandle.start_link(repo, name: via2)

      assert RepoRegistry.count() == 2
      assert Enum.sort(RepoRegistry.list()) == [url1, url2]

      RepoHandle.stop(h1)
      RepoHandle.stop(h2)
    end
  end
end
