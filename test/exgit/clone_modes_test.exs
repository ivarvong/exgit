defmodule Exgit.CloneModesTest do
  @moduledoc """
  Regression coverage for the `Exgit.clone/2` + `:lazy` / `:filter`
  API shape (post-API-review).

  Asserts the :mode contract:
    * `clone(url)` → `%Repository{mode: :eager}`
    * `clone(url, lazy: true)` → `%Repository{mode: :lazy}`
    * `clone(url, filter: ...)` → `%Repository{mode: :lazy}`
    * `clone(url, path: "...", lazy: true)` → `{:error, :disk_partial_clone_unsupported}`
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore
  alias Exgit.Repository

  # Small fake transport that serves a minimal repo. Enough to walk
  # through clone/2 without network.
  defmodule FakeT do
    defstruct [:refs, :store]
  end

  defimpl Exgit.Transport, for: Exgit.CloneModesTest.FakeT do
    alias Exgit.CloneModesTest.FakeT

    def capabilities(_), do: {:ok, %{:version => 2, "fetch" => "shallow filter"}}

    def ls_refs(%FakeT{refs: refs}, _opts), do: {:ok, refs, %{}}

    def fetch(%FakeT{store: store}, _wants, _opts) do
      objects =
        for {_sha, entry} <- store.objects do
          {type, compressed} = entry
          {:ok, obj} = Exgit.Object.decode(type, :zlib.uncompress(compressed))
          obj
        end

      pack = Exgit.Pack.Writer.build(objects)
      {:ok, pack, %{objects: length(objects)}}
    end

    def push(_, _, _, _), do: {:error, :unsupported}
  end

  defp seed_transport do
    store = ObjectStore.Memory.new()
    {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new("hello\n"))
    {:ok, tree_sha, store} = ObjectStore.put(store, Tree.new([{"100644", "hello.txt", blob_sha}]))

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "T <t@t> 1 +0000",
        committer: "T <t@t> 1 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)
    refs = [{"refs/heads/main", commit_sha}]
    %FakeT{refs: refs, store: store}
  end

  describe "clone/2 default mode" do
    test "returns an :eager repository" do
      assert {:ok, %Repository{mode: :eager}} = Exgit.clone(seed_transport())
    end
  end

  describe "clone/2 with lazy: true" do
    test "returns a :lazy repository" do
      assert {:ok, %Repository{mode: :lazy}} = Exgit.clone(seed_transport(), lazy: true)
    end

    test "object_store is a Promisor" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      assert %ObjectStore.Promisor{} = repo.object_store
    end
  end

  describe "clone/2 with filter" do
    test "filter: {:blob, :none} returns :lazy" do
      assert {:ok, %Repository{mode: :lazy}} =
               Exgit.clone(seed_transport(), filter: {:blob, :none})
    end
  end

  describe "clone/2 with path + lazy" do
    test "returns :disk_partial_clone_unsupported" do
      assert {:error, :disk_partial_clone_unsupported} =
               Exgit.clone(seed_transport(), path: "/tmp/unused", lazy: true)
    end

    test "returns :disk_partial_clone_unsupported with filter" do
      assert {:error, :disk_partial_clone_unsupported} =
               Exgit.clone(seed_transport(),
                 path: "/tmp/unused",
                 filter: {:blob, :none}
               )
    end
  end

  describe "Repository.materialize/2" do
    test "flips :lazy -> :eager" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      assert repo.mode == :lazy

      {:ok, materialized} = Repository.materialize(repo, "HEAD")
      assert materialized.mode == :eager
      # Object store is now the unwrapped Memory cache.
      refute match?(%ObjectStore.Promisor{}, materialized.object_store)
    end

    test "no-op on an :eager repo" do
      {:ok, repo} = Exgit.clone(seed_transport())
      {:ok, repo2} = Repository.materialize(repo, "HEAD")
      assert repo2 == repo
    end
  end

  describe "FS streaming ops gated on :mode" do
    test "FS.walk raises ArgumentError on :lazy repo" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)

      assert_raise ArgumentError, ~r/requires an :eager repository/, fn ->
        Exgit.FS.walk(repo, "HEAD") |> Enum.to_list()
      end
    end

    test "FS.grep raises ArgumentError on :lazy repo" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)

      assert_raise ArgumentError, ~r/requires an :eager repository/, fn ->
        Exgit.FS.grep(repo, "HEAD", "hello") |> Enum.to_list()
      end
    end

    test "FS.walk works after prefetch(blobs: true)" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
      # Prefetch with blobs: true flips :mode to :eager.
      assert repo.mode == :eager
      assert [{"hello.txt", _}] = Exgit.FS.walk(repo, "HEAD") |> Enum.to_list()
    end

    test "prefetch(blobs: false) does NOT flip mode" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: false)
      # Only trees, not blobs, so some objects are still missing.
      assert repo.mode == :lazy
    end

    test "prefetch(blobs: true, warm: true) populates blob_cache on the struct" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true, warm: true)

      # blob_cache is a plain map on the struct — no hidden state.
      assert is_map(repo.blob_cache)
      assert map_size(repo.blob_cache) > 0

      # Every value is a binary (raw blob content).
      assert Enum.all?(repo.blob_cache, fn {sha, data} ->
               is_binary(sha) and is_binary(data)
             end)
    end

    test "prefetch without warm: true leaves blob_cache empty" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)

      assert repo.blob_cache == %{}
    end

    test "grep uses blob_cache when populated — correct results unchanged" do
      {:ok, repo_cold} = Exgit.clone(seed_transport(), lazy: true)
      {:ok, repo_cold} = Exgit.FS.prefetch(repo_cold, "HEAD", blobs: true)

      {:ok, repo_warm} = Exgit.clone(seed_transport(), lazy: true)
      {:ok, repo_warm} = Exgit.FS.prefetch(repo_warm, "HEAD", blobs: true, warm: true)

      cold_hits =
        Exgit.FS.grep(repo_cold, "HEAD", "hello") |> Enum.map(& &1.line_number) |> Enum.sort()

      warm_hits =
        Exgit.FS.grep(repo_warm, "HEAD", "hello") |> Enum.map(& &1.line_number) |> Enum.sort()

      assert cold_hits == warm_hits,
             "blob_cache produced different grep results: #{inspect(cold_hits)} vs #{inspect(warm_hits)}"
    end

    test "warm_budget limits blob_cache size" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      # Budget of 1 byte — should result in an empty or partial cache.
      {:ok, repo_tiny} = Exgit.FS.prefetch(repo, "HEAD", blobs: true, warm: true, warm_budget: 1)

      {:ok, repo_full} = Exgit.FS.prefetch(repo, "HEAD", blobs: true, warm: true)

      # Tiny budget skips blobs (each blob is > 1 byte).
      assert map_size(repo_tiny.blob_cache) < map_size(repo_full.blob_cache)
    end

    test "FS.walk works after materialize/2" do
      {:ok, repo} = Exgit.clone(seed_transport(), lazy: true)
      {:ok, repo} = Repository.materialize(repo, "HEAD")
      assert [{"hello.txt", _}] = Exgit.FS.walk(repo, "HEAD") |> Enum.to_list()
    end
  end
end
