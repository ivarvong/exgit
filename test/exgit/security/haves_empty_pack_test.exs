defmodule Exgit.Security.HavesEmptyPackTest do
  @moduledoc """
  Offline regression for the partial-clone-haves bug.

  ## The bug

  After `clone(url, filter: {:blob, :none})`, on-demand blob fetches
  via the Promisor were sending every cached commit SHA as `have`
  lines. A smart `git-upload-pack` server (GitHub, Gerrit,
  ~anything running modern git) computes `want \\ reachable(haves)`
  and concludes: "the client has commit X, therefore they have
  everything reachable from X, therefore they already have this
  blob." Result: 32-byte empty pack, `{:error, :not_found}`.

  The fix removes haves from on-demand fetches. See the comment in
  `Promisor.fetch_and_cache/2`.

  ## Why this test exists (offline)

  The reporter found this against real GitHub. Our offline suite
  missed it because `FilterFakeT` (in `filter_test.exs`) is a
  "dumb" server that returns everything asked for regardless of
  haves. Real servers aren't dumb.

  This file defines `SmartFakeT` — a fake that actually implements
  the "exclude-reachable-from-haves" reduction that caused the
  real failure. Any future change that accidentally re-introduces
  sending haves on on-demand fetches will produce an empty pack
  here too, and the assertion `byte_size(blob.data) > 0` will
  fail.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore

  # Smart fake server. Implements the part of git-upload-pack that
  # matters for this bug: when computing what to send, exclude any
  # object reachable from the haves set.
  defmodule SmartFakeT do
    @moduledoc false
    defstruct [:origin, :refs]
  end

  defimpl Exgit.Transport, for: Exgit.Security.HavesEmptyPackTest.SmartFakeT do
    alias Exgit.Security.HavesEmptyPackTest.SmartFakeT

    def capabilities(_) do
      {:ok, %{:version => 2, "fetch" => "shallow filter sideband-all"}}
    end

    def ls_refs(%SmartFakeT{refs: refs}, _opts), do: {:ok, refs, %{}}

    def push(_, _, _, _), do: {:error, :unsupported}

    def fetch(%SmartFakeT{origin: origin}, wants, opts) do
      haves = Keyword.get(opts, :haves, [])
      filter = Keyword.get(opts, :filter)

      # Compute the closure of everything reachable from `haves`.
      # The server will EXCLUDE these from the response.
      excluded = reachable_closure(origin, haves)

      # Compute the closure of everything reachable from `wants`,
      # applying the filter (skip blobs when filter == "blob:none"),
      # then remove anything in `excluded`.
      wanted =
        wants
        |> Enum.flat_map(&reachable_with_filter(origin, &1, filter, MapSet.new()))
        |> Enum.uniq_by(&Exgit.Object.sha/1)

      final =
        Enum.reject(wanted, fn obj ->
          MapSet.member?(excluded, Exgit.Object.sha(obj))
        end)

      pack = Exgit.Pack.Writer.build(final)
      {:ok, pack, %{objects: length(final)}}
    end

    # Closure of reachability starting from `shas`. Returns a
    # MapSet of SHAs (not objects) — the server only cares about
    # "is this sha reachable?" for exclusion.
    defp reachable_closure(origin, shas) do
      Enum.reduce(shas, MapSet.new(), fn sha, acc ->
        close_from(origin, sha, acc)
      end)
    end

    defp close_from(origin, sha, acc) do
      if MapSet.member?(acc, sha) do
        acc
      else
        acc = MapSet.put(acc, sha)

        case Exgit.ObjectStore.get(origin, sha) do
          {:ok, %Commit{} = c} ->
            children = [Commit.tree(c) | Commit.parents(c)]
            Enum.reduce(children, acc, &close_from(origin, &1, &2))

          {:ok, %Tree{entries: entries}} ->
            Enum.reduce(entries, acc, fn {_mode, _name, child}, a ->
              close_from(origin, child, a)
            end)

          _ ->
            acc
        end
      end
    end

    # Walk `want` sha, applying filter. Returns a list of Object
    # structs that pass the filter.
    defp reachable_with_filter(origin, sha, filter, seen) do
      if MapSet.member?(seen, sha) do
        []
      else
        case Exgit.ObjectStore.get(origin, sha) do
          {:ok, %Commit{} = c} ->
            seen2 = MapSet.put(seen, sha)

            [c] ++
              reachable_with_filter(origin, Commit.tree(c), filter, seen2) ++
              Enum.flat_map(Commit.parents(c), &reachable_with_filter(origin, &1, filter, seen2))

          {:ok, %Tree{entries: entries} = t} ->
            seen2 = MapSet.put(seen, sha)

            children =
              Enum.flat_map(entries, fn {mode, _name, child_sha} ->
                blob? = mode != "40000"

                if blob? and filter == "blob:none" do
                  []
                else
                  reachable_with_filter(origin, child_sha, filter, seen2)
                end
              end)

            [t | children]

          {:ok, %Blob{} = b} ->
            if filter == "blob:none", do: [], else: [b]

          _ ->
            []
        end
      end
    end
  end

  # Build a tiny origin with a chain of commits so the "many haves
  # → empty pack" shape is present. Returns the store, the ref
  # list for ls_refs, and the sha of a blob we'll ask for later.
  defp build_origin do
    store = ObjectStore.Memory.new()

    blob = Blob.new("the content we want to read\n")
    {:ok, blob_sha, store} = ObjectStore.put(store, blob)

    tree = Tree.new([{"100644", "README.md", blob_sha}])
    {:ok, tree_sha, store} = ObjectStore.put(store, tree)

    # Build a chain of 5 commits to simulate a non-trivial history.
    # All 5 end up in the cache after the filter-based initial
    # fetch, so if haves were sent on the on-demand blob fetch,
    # all 5 would appear in the haves list → empty pack.
    {head_sha, store} =
      Enum.reduce(1..5, {nil, store}, fn i, {parent, s} ->
        commit =
          Commit.new(
            tree: tree_sha,
            parents: if(parent, do: [parent], else: []),
            author: "A <a@a.com> #{1_700_000_000 + i} +0000",
            committer: "A <a@a.com> #{1_700_000_000 + i} +0000",
            message: "commit #{i}\n"
          )

        {:ok, c_sha, s} = ObjectStore.put(s, commit)
        {c_sha, s}
      end)

    refs = [{"HEAD", head_sha}, {"refs/heads/main", head_sha}]
    {store, refs, blob_sha}
  end

  test "on-demand blob fetch against a smart server after a partial clone" do
    # This is the reporter's exact scenario, offline.
    # The test asserts that:
    #   1. The partial clone succeeds.
    #   2. The on-demand blob fetch returns a NON-EMPTY pack.
    #   3. FS.read_path returns the actual blob content.
    {origin, refs, _blob_sha} = build_origin()
    t = %SmartFakeT{origin: origin, refs: refs}

    {:ok, repo} = Exgit.clone(t, filter: {:blob, :none})
    assert repo.mode == :lazy

    # This is the specific call that produced {:error, :not_found}
    # before the fix. The bug was: the Promisor's on-demand fetch
    # sent every cached commit sha as haves, the SmartFakeT
    # excluded the blob's reachability closure, and returned zero
    # objects.
    assert {:ok, {_mode, blob}, _repo} =
             Exgit.FS.read_path(repo, "HEAD", "README.md")

    assert blob.data == "the content we want to read\n"
  end

  test "ls works before any blob fetch (trees are eagerly prefetched)" do
    # Sanity-check: the partial clone's initial tree-only fetch
    # works. If THIS breaks, it's a different bug from the haves
    # regression.
    {origin, refs, _blob_sha} = build_origin()
    t = %SmartFakeT{origin: origin, refs: refs}

    {:ok, repo} = Exgit.clone(t, filter: {:blob, :none})

    assert {:ok, entries, _repo} = Exgit.FS.ls(repo, "HEAD", "")
    names = for {_mode, name, _sha} <- entries, do: name
    assert "README.md" in names
  end

  test "lazy clone (no filter) works against the smart server" do
    # Lazy clone → every read_path triggers on-demand commit + tree
    # + blob fetches. The haves-empty-pack bug would break this
    # too, since the second-and-later fetches have commits in the
    # cache already.
    {origin, refs, _blob_sha} = build_origin()
    t = %SmartFakeT{origin: origin, refs: refs}

    {:ok, repo} = Exgit.clone(t, lazy: true)

    assert {:ok, {_mode, blob}, _repo} =
             Exgit.FS.read_path(repo, "HEAD", "README.md")

    assert blob.data == "the content we want to read\n"
  end
end
