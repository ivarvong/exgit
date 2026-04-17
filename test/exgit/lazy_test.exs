defmodule Exgit.LazyTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{FS, ObjectStore, RefStore}

  @moduledoc """
  Lazy-mode tests.

  Lazy mode clones refs only. Objects are fetched on demand through a
  promisor object store that asks a transport for `want <sha>` and
  caches the result.

  To drive this hermetically we use a FakeTransport that implements
  `Exgit.Transport` and serves objects from a pre-populated "origin"
  store. It records every `fetch/3` call so we can assert that:

    * lazy_clone did NOT fetch any blobs/trees/commits up front
    * the first FS.read_path triggered a fetch
    * a second FS.read_path of the same sha hit the cache, NOT the
      network (fetch call count didn't grow)
  """

  defmodule FakeTransport do
    defstruct [:agent]

    def new(store, refs) do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{store: store, refs: refs, fetch_calls: [], ls_refs_calls: 0}
        end)

      %__MODULE__{agent: agent}
    end

    def fetch_calls(%__MODULE__{agent: a}),
      do: Agent.get(a, & &1.fetch_calls) |> Enum.reverse()

    def ls_refs_count(%__MODULE__{agent: a}), do: Agent.get(a, & &1.ls_refs_calls)
  end

  defimpl Exgit.Transport, for: Exgit.LazyTest.FakeTransport do
    alias Exgit.LazyTest.FakeTransport

    def capabilities(%FakeTransport{}), do: {:ok, %{version: 2}}

    def ls_refs(%FakeTransport{agent: a}, _opts) do
      Agent.update(a, &%{&1 | ls_refs_calls: &1.ls_refs_calls + 1})
      refs = Agent.get(a, & &1.refs)
      {:ok, refs}
    end

    def fetch(%FakeTransport{agent: a}, wants, _opts) do
      Agent.update(a, &%{&1 | fetch_calls: [wants | &1.fetch_calls]})

      store = Agent.get(a, & &1.store)

      # Collect wanted objects + their transitive dependencies (for a
      # commit: its tree; for a tree: its entries). Real servers do the
      # same via the want/have negotiation; we short-circuit it.
      objects =
        wants
        |> Enum.flat_map(&reachable(store, &1))
        |> Enum.uniq_by(&Exgit.Object.sha/1)

      # Build a pack.
      pack = Exgit.Pack.Writer.build(objects)
      {:ok, pack, %{objects: length(objects)}}
    end

    def push(%FakeTransport{}, _, _, _), do: {:error, :push_unsupported}

    defp reachable(store, sha) do
      case ObjectStore.get(store, sha) do
        {:ok, %Exgit.Object.Commit{} = c} ->
          [c | reachable(store, Exgit.Object.Commit.tree(c))]

        {:ok, %Exgit.Object.Tree{entries: entries} = t} ->
          children =
            Enum.flat_map(entries, fn {_mode, _name, child_sha} ->
              reachable(store, child_sha)
            end)

          [t | children]

        {:ok, obj} ->
          [obj]

        _ ->
          []
      end
    end
  end

  setup do
    # Build an "origin" repo with a small tree:
    #   README.md  → "hello\n"
    #   src/a.ex   → "module A"
    store = ObjectStore.Memory.new()

    readme = Blob.new("hello\n")
    {:ok, readme_sha, store} = ObjectStore.put(store, readme)

    a = Blob.new("defmodule A do end\n")
    {:ok, a_sha, store} = ObjectStore.put(store, a)

    src_tree = Tree.new([{"100644", "a.ex", a_sha}])
    {:ok, src_sha, store} = ObjectStore.put(store, src_tree)

    root = Tree.new([{"100644", "README.md", readme_sha}, {"40000", "src", src_sha}])
    {:ok, root_sha, store} = ObjectStore.put(store, root)

    commit =
      Commit.new(
        tree: root_sha,
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)

    refs = [{"refs/heads/main", commit_sha}, {"HEAD", commit_sha}]

    transport = FakeTransport.new(store, refs)

    {:ok,
     transport: transport,
     shas: %{
       commit: commit_sha,
       root: root_sha,
       src: src_sha,
       readme: readme_sha,
       a: a_sha
     }}
  end

  describe "lazy_clone (L.1)" do
    test "clones refs only, no objects fetched up front", %{transport: t} do
      assert {:ok, repo} = Exgit.lazy_clone(t)

      # Refs present.
      assert {:ok, _head_sha} = RefStore.resolve(repo.ref_store, "HEAD")

      # ls_refs happened once.
      assert FakeTransport.ls_refs_count(t) == 1

      # No fetch yet.
      assert FakeTransport.fetch_calls(t) == []
    end

    test "FS.read_path on a lazy repo triggers a fetch and returns the blob + updated repo",
         %{transport: t, shas: shas} do
      {:ok, repo} = Exgit.lazy_clone(t)

      assert {:ok, {_mode, %Blob{data: "hello\n"}}, _repo} =
               FS.read_path(repo, "HEAD", "README.md")

      # At least one fetch happened.
      calls = FakeTransport.fetch_calls(t)
      assert length(calls) >= 1

      # The commit SHA was among the first batch (to resolve HEAD's tree).
      assert Enum.any?(List.flatten(calls), &(&1 == shas.commit))
    end

    test "threading the returned repo forward hits the cache on the next read",
         %{transport: t} do
      {:ok, repo} = Exgit.lazy_clone(t)

      {:ok, _, repo} = FS.read_path(repo, "HEAD", "README.md")
      first_count = length(FakeTransport.fetch_calls(t))

      # Thread `repo` forward — second call benefits from the cached objects.
      {:ok, _, _repo} = FS.read_path(repo, "HEAD", "README.md")
      second_count = length(FakeTransport.fetch_calls(t))

      assert second_count == first_count,
             "threaded second read should not trigger a fetch " <>
               "(before=#{first_count}, after=#{second_count})"
    end

    test "NOT threading the repo back re-triggers a fetch (documenting stateless semantics)",
         %{transport: t} do
      {:ok, repo} = Exgit.lazy_clone(t)

      # Discard the updated repo.
      {:ok, _, _discarded} = FS.read_path(repo, "HEAD", "README.md")
      first_count = length(FakeTransport.fetch_calls(t))

      # Using the ORIGINAL repo again — its cache is still empty, so
      # another fetch happens. This is the intentional contract: the
      # Promisor is a pure value.
      {:ok, _, _discarded} = FS.read_path(repo, "HEAD", "README.md")
      second_count = length(FakeTransport.fetch_calls(t))

      assert second_count > first_count,
             "discarding the returned repo should re-trigger a fetch " <>
               "(before=#{first_count}, after=#{second_count})"
    end

    test "FS.ls threads an updated repo — second ls via threaded repo skips fetch",
         %{transport: t} do
      {:ok, repo} = Exgit.lazy_clone(t)

      {:ok, entries, repo} = FS.ls(repo, "HEAD", "src")
      names = for {_, n, _} <- entries, do: n
      assert names == ["a.ex"]

      before = length(FakeTransport.fetch_calls(t))
      {:ok, _, _repo} = FS.ls(repo, "HEAD", "src")
      after_ = length(FakeTransport.fetch_calls(t))

      assert after_ == before
    end

    test "reading a different blob after the first still works", %{transport: t} do
      {:ok, repo} = Exgit.lazy_clone(t)

      assert {:ok, {_, %Blob{data: "hello\n"}}, repo} =
               FS.read_path(repo, "HEAD", "README.md")

      assert {:ok, {_, %Blob{data: "defmodule A do end\n"}}, _repo} =
               FS.read_path(repo, "HEAD", "src/a.ex")
    end

    test "missing paths surface as :not_found, not as transport errors", %{transport: t} do
      {:ok, repo} = Exgit.lazy_clone(t)

      assert {:error, :not_found} = FS.read_path(repo, "HEAD", "does/not/exist")
    end
  end
end
