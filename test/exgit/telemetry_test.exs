defmodule Exgit.TelemetryTest do
  # async: false — :telemetry handlers are registered globally, so
  # running this test concurrently with other tests that fire the same
  # events (Promisor.resolve in lazy_test, filter_test, etc.) leaks
  # events into this test's mailbox. Serial execution gives clean
  # telemetry measurements.
  use ExUnit.Case, async: false

  alias Exgit.Object.Blob
  alias Exgit.{ObjectStore, RefStore}

  @moduledoc """
  Tests that exgit's public operations emit the documented telemetry
  events with the documented metadata.

  We attach a single handler per test case (unique handler id) and
  collect events in the test process's mailbox for assertion.
  """

  # Named handler — avoids telemetry's local-function performance warning.
  def forward_event(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end

  setup context do
    # Unique handler name per test so async tests don't collide.
    handler = "exgit-test-#{inspect(context.test)}"

    events = [
      [:exgit, :transport, :fetch, :start],
      [:exgit, :transport, :fetch, :stop],
      [:exgit, :transport, :ls_refs, :start],
      [:exgit, :transport, :ls_refs, :stop],
      [:exgit, :object_store, :get, :start],
      [:exgit, :object_store, :get, :stop],
      [:exgit, :object_store, :put, :stop],
      [:exgit, :pack, :parse, :start],
      [:exgit, :pack, :parse, :stop],
      [:exgit, :fs, :read_path, :start],
      [:exgit, :fs, :read_path, :stop],
      [:exgit, :fs, :ls, :stop],
      [:exgit, :fs, :walk, :stop],
      [:exgit, :fs, :grep, :stop]
    ]

    :telemetry.attach_many(handler, events, &__MODULE__.forward_event/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok
  end

  defp build_tiny_repo do
    store = ObjectStore.Memory.new()

    blob = Blob.new("hello\n")
    {:ok, blob_sha, store} = ObjectStore.put(store, blob)

    tree = Exgit.Object.Tree.new([{"100644", "readme.md", blob_sha}])
    {:ok, tree_sha, store} = ObjectStore.put(store, tree)

    commit =
      Exgit.Object.Commit.new(
        tree: tree_sha,
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)

    {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
    {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

    %Exgit.Repository{
      object_store: store,
      ref_store: ref_store,
      config: Exgit.Config.new(),
      path: nil
    }
  end

  defp drain_events do
    drain_events([])
  end

  defp drain_events(acc) do
    receive do
      {:telemetry, event, m, md} -> drain_events([{event, m, md} | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  describe "FS.read_path emits telemetry" do
    test "fires :start, :stop with duration, :reference and :path in metadata" do
      repo = build_tiny_repo()
      {:ok, _, _repo} = Exgit.FS.read_path(repo, "HEAD", "readme.md")

      events = drain_events()

      start = Enum.find(events, fn {e, _, _} -> e == [:exgit, :fs, :read_path, :start] end)
      stop = Enum.find(events, fn {e, _, _} -> e == [:exgit, :fs, :read_path, :stop] end)

      assert start, "expected :start event"
      assert stop, "expected :stop event"

      {_, start_m, start_md} = start
      assert is_integer(start_m.system_time)
      assert start_md.reference == "HEAD"
      assert start_md.path == "readme.md"

      {_, stop_m, _} = stop
      assert is_integer(stop_m.duration)
      assert stop_m.duration > 0
    end

    test "read_path fires ObjectStore.get events for each object it touches" do
      repo = build_tiny_repo()
      {:ok, _, _repo} = Exgit.FS.read_path(repo, "HEAD", "readme.md")

      events = drain_events()

      get_stops =
        Enum.filter(events, fn {e, _, _} -> e == [:exgit, :object_store, :get, :stop] end)

      # Touches: commit (to get tree sha) + root tree + blob = 3.
      assert length(get_stops) >= 3
    end
  end

  describe "FS.ls emits telemetry" do
    test "stop metadata includes entry_count" do
      repo = build_tiny_repo()
      {:ok, _, _repo} = Exgit.FS.ls(repo, "HEAD", "")

      events = drain_events()
      {_, _, md} = Enum.find(events, fn {e, _, _} -> e == [:exgit, :fs, :ls, :stop] end)

      assert md.entry_count == 1
    end
  end

  describe "FS.grep emits telemetry with match_count" do
    test "grep reports the number of matches in :stop metadata" do
      repo = build_tiny_repo()
      matches = Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()

      events = drain_events()
      {_, _, md} = Enum.find(events, fn {e, _, _} -> e == [:exgit, :fs, :grep, :stop] end)

      assert md.match_count == length(matches)
      assert md.match_count == 1
    end
  end

  describe "ObjectStore telemetry" do
    test "put reports sha in metadata" do
      store = ObjectStore.Memory.new()
      blob = Blob.new("x")

      {:ok, sha, _} = ObjectStore.put(store, blob)

      events = drain_events()

      {_, _, md} =
        Enum.find(events, fn {e, _, _} -> e == [:exgit, :object_store, :put, :stop] end)

      assert md.sha == sha
    end

    test "Promisor.resolve fires fetch_and_cache exactly once, hitting the cache on re-resolve" do
      defmodule FakeT do
        defstruct [:store]
        def new(store), do: %__MODULE__{store: store}
      end

      defimpl Exgit.Transport, for: Exgit.TelemetryTest.FakeT do
        alias Exgit.TelemetryTest.FakeT

        def capabilities(_), do: {:ok, %{version: 2}}
        def ls_refs(_, _), do: {:ok, [], %{}}
        def push(_, _, _, _), do: {:error, :unsupported}

        def fetch(%FakeT{store: store}, wants, _opts) do
          objects =
            for sha <- wants do
              case Exgit.ObjectStore.get(store, sha) do
                {:ok, obj} -> obj
                _ -> nil
              end
            end
            |> Enum.reject(&is_nil/1)

          pack = Exgit.Pack.Writer.build(objects)
          {:ok, pack, %{objects: length(objects)}}
        end
      end

      # Separate handler for fetch_and_cache which isn't in the shared
      # setup list.
      handler = "fac-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:exgit, :object_store, :fetch_and_cache, :start],
          [:exgit, :object_store, :fetch_and_cache, :stop]
        ],
        &__MODULE__.forward_event/4,
        self()
      )

      try do
        origin = ObjectStore.Memory.new()
        blob = Blob.new("lazy-telemetry\n")
        {:ok, sha, origin} = ObjectStore.put(origin, blob)

        promisor = ObjectStore.Promisor.new(FakeT.new(origin))

        # First resolve → miss → triggers fetch_and_cache.
        {:ok, ^blob, promisor} = ObjectStore.Promisor.resolve(promisor, sha)
        # Second resolve (threaded) → cache hit → no fetch_and_cache.
        {:ok, ^blob, _} = ObjectStore.Promisor.resolve(promisor, sha)

        events = drain_events()

        fac_stops =
          Enum.filter(events, fn {e, _, _} ->
            e == [:exgit, :object_store, :fetch_and_cache, :stop]
          end)

        assert length(fac_stops) == 1,
               "expected exactly one fetch_and_cache cycle, got #{length(fac_stops)}"

        {_, _, md} = hd(fac_stops)
        assert md.object_count == 1
      after
        :telemetry.detach(handler)
      end
    end
  end
end
