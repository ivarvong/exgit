defmodule Exgit.ObjectStore.SharedPromisorTest do
  @moduledoc """
  Coverage for the SharedPromisor GenServer wrapper.

  Tests two things:
    1. Functional correctness — each public call matches the pure
       Promisor's behavior.
    2. Concurrency — N parallel resolves against the same wrapper
       produce a strictly-larger merged cache than the same calls
       against separate pure Promisors would (the cache race
       mitigation).
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore
  alias Exgit.ObjectStore.{Promisor, SharedPromisor}

  # Stub transport that serves objects from a preloaded store.
  defmodule StubT do
    defstruct [:store]
  end

  defimpl Exgit.Transport, for: Exgit.ObjectStore.SharedPromisorTest.StubT do
    alias Exgit.ObjectStore.SharedPromisorTest.StubT

    def capabilities(_), do: {:ok, %{version: 2}}
    def ls_refs(_, _), do: {:ok, [], %{}}

    def fetch(%StubT{store: origin}, wants, _opts) do
      objects =
        for sha <- wants, {:ok, obj} <- [Exgit.ObjectStore.get(origin, sha)], do: obj

      pack = Exgit.Pack.Writer.build(objects)
      {:ok, pack, %{objects: length(objects)}}
    end

    def push(_, _, _, _), do: {:error, :unsupported}
  end

  defp origin_with_blobs(0), do: {ObjectStore.Memory.new(), []}

  defp origin_with_blobs(n) when n > 0 do
    Enum.reduce(1..n, {ObjectStore.Memory.new(), []}, fn i, {store, shas} ->
      blob = Blob.new("blob_#{i}\n")
      {:ok, sha, store} = ObjectStore.put(store, blob)
      {store, [sha | shas]}
    end)
  end

  describe "basic API" do
    test "resolve/2 fetches, caches, and reads back" do
      {origin, [sha | _]} = origin_with_blobs(3)
      {:ok, pid} = SharedPromisor.start_link(Promisor.new(%StubT{store: origin}))

      assert {:ok, %Blob{data: "blob_3\n"}} = SharedPromisor.resolve(pid, sha)

      # Second call is a cache hit; same pid, same result.
      assert {:ok, %Blob{data: "blob_3\n"}} = SharedPromisor.resolve(pid, sha)
    end

    test "put/2 + get/2 roundtrip" do
      {origin, _} = origin_with_blobs(0)
      {:ok, pid} = SharedPromisor.start_link(Promisor.new(%StubT{store: origin}))

      blob = Blob.new("direct insert\n")
      assert {:ok, sha} = SharedPromisor.put(pid, blob)
      assert {:ok, ^blob} = SharedPromisor.get(pid, sha)
      assert SharedPromisor.has_object?(pid, sha)
    end

    test "empty?/1 on a fresh wrapper" do
      {origin, _} = origin_with_blobs(0)
      {:ok, pid} = SharedPromisor.start_link(Promisor.new(%StubT{store: origin}))

      assert SharedPromisor.empty?(pid)
    end

    test "snapshot/1 returns the underlying Promisor" do
      {origin, _} = origin_with_blobs(0)
      {:ok, pid} = SharedPromisor.start_link(Promisor.new(%StubT{store: origin}))

      blob = Blob.new("snap\n")
      {:ok, _sha} = SharedPromisor.put(pid, blob)

      assert %Promisor{} = snap = SharedPromisor.snapshot(pid)
      refute Promisor.empty?(snap)
    end

    test "resolve/2 returns {:error, :not_found} when fetch can't find the sha" do
      {origin, _} = origin_with_blobs(0)
      {:ok, pid} = SharedPromisor.start_link(Promisor.new(%StubT{store: origin}))

      missing = :binary.copy(<<0xBB>>, 20)
      assert {:error, :not_found} = SharedPromisor.resolve(pid, missing)
    end
  end

  describe "concurrency (the whole point)" do
    test "N parallel resolves all see each other's cache growth" do
      # Seed an origin with 20 blobs. Fire 20 parallel resolves
      # against a single SharedPromisor. All 20 SHAs must end up
      # in the cache, regardless of which task's call completed
      # first.
      {origin, shas} = origin_with_blobs(20)
      {:ok, pid} = SharedPromisor.start_link(Promisor.new(%StubT{store: origin}))

      # Parallel resolve.
      _results =
        shas
        |> Enum.map(fn sha -> Task.async(fn -> SharedPromisor.resolve(pid, sha) end) end)
        |> Task.await_many(10_000)

      # Every blob must now be in the cache.
      snap = SharedPromisor.snapshot(pid)

      for sha <- shas do
        assert {:ok, %Blob{}} = ObjectStore.get(snap.cache, sha),
               "missing #{Base.encode16(sha, case: :lower)} in merged cache"
      end
    end

    test "pure Promisor, by contrast, loses writes under parallel resolve" do
      # Demonstration: the pure-value Promisor can't merge concurrent
      # cache growths. This test exists to document WHY SharedPromisor
      # exists.
      {origin, shas} = origin_with_blobs(5)
      p0 = Promisor.new(%StubT{store: origin})

      # Every task starts from p0 and returns its own promisor. We
      # only get ONE back; the rest are discarded by message passing.
      [task_result | _] =
        shas
        |> Enum.map(fn sha ->
          Task.async(fn ->
            {:ok, _obj, p} = Promisor.resolve(p0, sha)
            p
          end)
        end)
        |> Task.await_many(10_000)

      # task_result has only the single sha that task resolved.
      # The remaining 4 are "lost" from its cache (though they're
      # in the caches of the other 4 tasks, which were discarded).
      cached_count =
        Enum.count(shas, fn sha ->
          match?({:ok, _}, ObjectStore.get(task_result.cache, sha))
        end)

      assert cached_count == 1,
             "expected pure Promisor to lose 4 of 5 parallel writes, got #{cached_count}"
    end
  end

  describe "start_link options" do
    test "accepts a :name registration" do
      {origin, _} = origin_with_blobs(0)
      name = :"shared_promisor_test_#{System.unique_integer([:positive])}"

      {:ok, pid} = SharedPromisor.start_link(Promisor.new(%StubT{store: origin}), name: name)
      assert Process.whereis(name) == pid

      assert SharedPromisor.empty?(name)
    end
  end

  describe "overfull forwarding" do
    test ":error policy on the wrapped Promisor surfaces through put/2" do
      {origin, _} = origin_with_blobs(0)
      p = Promisor.new(%StubT{store: origin}, max_cache_bytes: 1, on_overfull: :error)
      {:ok, pid} = SharedPromisor.start_link(p)

      # First put over cap returns the error shape (no 3-tuple —
      # SharedPromisor callers don't need to thread state).
      assert {:error, :cache_overfull} = SharedPromisor.put(pid, Blob.new("too big\n"))
    end
  end
end
