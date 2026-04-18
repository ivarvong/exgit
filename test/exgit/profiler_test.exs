defmodule Exgit.ProfilerTest do
  @moduledoc """
  Tests the structured-trace profiler. Primary contract: running
  a function under `profile/1` captures every exgit telemetry
  span emitted during the call, aggregates per-event counts and
  total microseconds, and reports peak cache_bytes observed via
  metadata.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore.Memory
  alias Exgit.Profiler
  alias Exgit.Repository

  setup do
    store = Memory.new()

    {:ok, blob_sha, store} = Exgit.ObjectStore.put(store, Blob.new("hello\n"))

    {:ok, tree_sha, store} =
      Exgit.ObjectStore.put(
        store,
        Exgit.Object.Tree.new([{"100644", "a.txt", blob_sha}])
      )

    commit =
      Exgit.Object.Commit.new(
        tree: tree_sha,
        parents: [],
        author: "A <a@a.com> 1 +0000",
        committer: "A <a@a.com> 1 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = Exgit.ObjectStore.put(store, commit)

    ref_store = Exgit.RefStore.Memory.new()
    {:ok, ref_store} = Exgit.RefStore.write(ref_store, "refs/heads/main", commit_sha, [])
    {:ok, ref_store} = Exgit.RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = Repository.new(store, ref_store)
    {:ok, repo: repo}
  end

  describe "profile/1" do
    test "captures events emitted during the function body", %{repo: repo} do
      {result, profile} =
        Profiler.profile(fn ->
          Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
        end)

      assert [%{path: "a.txt"}] = result
      assert is_list(profile.events)
      assert profile.total_us > 0

      # At minimum, fs.grep fired one stop event.
      assert Map.has_key?(profile.totals, "fs.grep")
      assert profile.totals["fs.grep"].count == 1
    end

    test "returns structured totals", %{repo: repo} do
      {_, profile} =
        Profiler.profile(fn ->
          Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
          Exgit.FS.read_path(repo, "HEAD", "a.txt")
        end)

      # fs.grep + fs.read_path + walk/get events should appear.
      assert Map.has_key?(profile.totals, "fs.grep")
      assert Map.has_key?(profile.totals, "fs.read_path")

      # Each count is a non-negative integer.
      for {_event, %{count: c, us: us}} <- profile.totals do
        assert is_integer(c) and c >= 0
        assert is_integer(us) and us >= 0
      end
    end

    test "events are returned in chronological order", %{repo: repo} do
      {_, profile} =
        Profiler.profile(fn ->
          Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
        end)

      starts = Enum.map(profile.events, & &1.started_at)
      assert starts == Enum.sort(starts)
    end

    test "profile is empty when no exgit telemetry fires" do
      {result, profile} = Profiler.profile(fn -> 1 + 1 end)
      assert result == 2
      assert profile.events == []
      assert profile.totals == %{}
      assert profile.peak_cache_bytes == :unknown
    end

    test "detach is called even if the function raises", %{repo: repo} do
      before_attached = :telemetry.list_handlers([:exgit])

      assert_raise RuntimeError, "boom", fn ->
        Profiler.profile(fn ->
          Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
          raise "boom"
        end)
      end

      after_attached = :telemetry.list_handlers([:exgit])
      # All exgit-profiler-* handlers should be gone even though we
      # raised. Count the profiler-named handlers before and after.
      before_count =
        Enum.count(before_attached, &String.starts_with?(&1.id, "exgit-profiler-"))

      after_count =
        Enum.count(after_attached, &String.starts_with?(&1.id, "exgit-profiler-"))

      assert after_count == before_count
    end
  end

  describe "attach/read/detach" do
    test "manual attach + read + detach flow", %{repo: repo} do
      {:ok, handle} = Profiler.attach()

      try do
        Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
        profile = Profiler.read(handle)

        assert Map.has_key?(profile.totals, "fs.grep")
      after
        Profiler.detach(handle)
      end
    end

    test "multiple reads accumulate until detach", %{repo: repo} do
      {:ok, handle} = Profiler.attach()

      Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
      p1 = Profiler.read(handle)

      Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
      p2 = Profiler.read(handle)

      assert p2.totals["fs.grep"].count > p1.totals["fs.grep"].count

      Profiler.detach(handle)
    end

    test "detach cleans up the ETS table", %{repo: repo} do
      {:ok, handle} = Profiler.attach()
      Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
      Profiler.detach(handle)

      # Reading after detach should raise (table is gone).
      assert_raise ArgumentError, fn -> Profiler.read(handle) end
    end
  end
end
