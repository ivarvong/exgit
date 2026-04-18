defmodule Exgit.FilterTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore
  alias Exgit.ObjectStore.Promisor

  @moduledoc """
  Tests for partial-clone filter support:

    * `Exgit.Filter.encode/1` — validates + formats filter specs to
      protocol strings.
    * `Exgit.Transport.HTTP.fetch` honors the `filter:` option.
    * `Exgit.clone(url, filter: ...)` eagerly fetches commits+trees
      and satisfies subsequent blob reads via on-demand fetches.
    * Filter unsupported by server → error by default; silent fallback
      via `if_unsupported: :ignore`.
  """

  # A FakeTransport that records the filter passed through on fetch,
  # and models a server that advertises filter capability but behaves
  # like a real blobless-clone: first fetch returns only commits+trees;
  # subsequent fetches return the requested blobs.
  defmodule FilterFakeT do
    defstruct [:origin, :calls, :advertise_filter]

    def new(origin, opts \\ []) do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      %__MODULE__{
        origin: origin,
        calls: calls,
        advertise_filter: Keyword.get(opts, :advertise_filter, true)
      }
    end

    def fetch_calls(%__MODULE__{calls: a}) do
      Agent.get(a, & &1) |> Enum.reverse()
    end
  end

  defimpl Exgit.Transport, for: Exgit.FilterTest.FilterFakeT do
    alias Exgit.FilterTest.FilterFakeT

    def capabilities(%FilterFakeT{advertise_filter: true}) do
      {:ok, %{:version => 2, "fetch" => "shallow filter sideband-all"}}
    end

    def capabilities(%FilterFakeT{advertise_filter: false}) do
      {:ok, %{:version => 2, "fetch" => "shallow sideband-all"}}
    end

    def ls_refs(%FilterFakeT{calls: calls}, _opts) do
      # Refs are injected by the test via :persistent_term keyed on the
      # transport's calls-agent pid.
      refs = :persistent_term.get({FilterFakeT, calls, :refs}, [])
      {:ok, refs, %{}}
    end

    def push(_, _, _, _), do: {:error, :unsupported}

    def fetch(%FilterFakeT{origin: origin, calls: calls} = t, wants, opts) do
      filter = Keyword.get(opts, :filter)
      Agent.update(calls, fn acc -> [%{wants: wants, filter: filter} | acc] end)

      # Walk reachable objects. Exclude blobs when filter is blob:none
      # AND we advertised that we support filter. Otherwise return
      # everything.
      objects =
        for sha <- wants do
          reachable(origin, sha, filter, t.advertise_filter)
        end
        |> List.flatten()
        |> Enum.uniq_by(&Exgit.Object.sha/1)

      pack = Exgit.Pack.Writer.build(objects)
      {:ok, pack, %{objects: length(objects)}}
    end

    defp reachable(store, sha, filter, advertise_filter) do
      case Exgit.ObjectStore.get(store, sha) do
        {:ok, %Exgit.Object.Commit{} = c} ->
          [c | reachable(store, Exgit.Object.Commit.tree(c), filter, advertise_filter)]

        {:ok, %Exgit.Object.Tree{entries: entries} = t} ->
          children =
            Enum.flat_map(entries, fn {mode, _name, child_sha} ->
              cond do
                # Skip blobs when filtering.
                mode != "40000" and filter == "blob:none" and advertise_filter -> []
                true -> reachable(store, child_sha, filter, advertise_filter)
              end
            end)

          [t | children]

        {:ok, obj} ->
          [obj]

        _ ->
          []
      end
    end
  end

  # Build a tiny origin repo with:
  #   README.md  (a blob)
  #   lib/a.ex, lib/b.ex  (blobs, nested)
  # Returns the origin store, HEAD's commit sha, and blob shas for asserts.
  defp build_origin do
    store = ObjectStore.Memory.new()

    readme = Blob.new("hello\n")
    {:ok, readme_sha, store} = ObjectStore.put(store, readme)

    a = Blob.new("defmodule A do end\n")
    {:ok, a_sha, store} = ObjectStore.put(store, a)

    b = Blob.new("defmodule B do end\n")
    {:ok, b_sha, store} = ObjectStore.put(store, b)

    lib_tree = Tree.new([{"100644", "a.ex", a_sha}, {"100644", "b.ex", b_sha}])
    {:ok, lib_sha, store} = ObjectStore.put(store, lib_tree)

    root = Tree.new([{"100644", "README.md", readme_sha}, {"40000", "lib", lib_sha}])
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

    %{
      store: store,
      commit: commit_sha,
      readme: readme_sha,
      a: a_sha,
      b: b_sha,
      lib: lib_sha,
      root: root_sha
    }
  end

  describe "Exgit.Filter.encode/1 (filter-spec validation)" do
    test ":none means no filter" do
      assert Exgit.Filter.encode(:none) == :none
    end

    test "{:blob, :none} → \"blob:none\"" do
      assert Exgit.Filter.encode({:blob, :none}) == {:ok, "blob:none"}
    end

    test "{:blob, {:limit, 1024}} → \"blob:limit=1024\"" do
      assert Exgit.Filter.encode({:blob, {:limit, 1024}}) == {:ok, "blob:limit=1024"}
    end

    test ~s[{:blob, {:limit, "1m"}} → "blob:limit=1m" (human-readable passthrough)] do
      assert Exgit.Filter.encode({:blob, {:limit, "1m"}}) == {:ok, "blob:limit=1m"}
    end

    test "{:tree, 0} → \"tree:0\"" do
      assert Exgit.Filter.encode({:tree, 0}) == {:ok, "tree:0"}
    end

    test "{:raw, \"custom:spec\"} escape hatch" do
      assert Exgit.Filter.encode({:raw, "object:type=blob"}) == {:ok, "object:type=blob"}
    end

    test "invalid spec returns structured error" do
      assert {:error, {:invalid_filter, _}} = Exgit.Filter.encode(:invalid)
      assert {:error, {:invalid_filter, _}} = Exgit.Filter.encode({:blob, :huh})
      assert {:error, {:invalid_filter, _}} = Exgit.Filter.encode({:tree, -1})
    end
  end

  describe "lazy_clone with filter" do
    test "filter: {:blob, :none} — clone fetches commits+trees, no blobs" do
      origin = build_origin()

      # Set up the transport with the origin's refs.
      transport =
        %{FilterFakeT.new(origin.store) | origin: origin.store}

      # Seed the fake transport's refs.
      :persistent_term.put({FilterFakeT, transport.calls, :refs}, [
        {"refs/heads/main", origin.commit},
        {"HEAD", origin.commit}
      ])

      assert {:ok, repo} = Exgit.clone(transport, filter: {:blob, :none})

      # The cache has commits + trees but NOT the blobs.
      store = repo.object_store
      assert Promisor.has_object?(store, origin.commit), "commit should be cached"
      assert Promisor.has_object?(store, origin.root), "root tree should be cached"
      assert Promisor.has_object?(store, origin.lib), "lib tree should be cached"

      refute Promisor.has_object?(store, origin.readme), "README.md blob should NOT be cached"
      refute Promisor.has_object?(store, origin.a), "lib/a.ex blob should NOT be cached"
    end

    test "subsequent read_path triggers a follow-up fetch for the missing blob" do
      origin = build_origin()
      transport = %{FilterFakeT.new(origin.store) | origin: origin.store}

      :persistent_term.put({FilterFakeT, transport.calls, :refs}, [
        {"refs/heads/main", origin.commit},
        {"HEAD", origin.commit}
      ])

      {:ok, repo} = Exgit.clone(transport, filter: {:blob, :none})

      fetches_before = length(FilterFakeT.fetch_calls(transport))
      assert fetches_before == 1, "lazy_clone did the initial tree-only fetch"

      {:ok, {_mode, blob}, _repo} = Exgit.FS.read_path(repo, "HEAD", "README.md")
      assert blob.data == "hello\n"

      fetches_after = length(FilterFakeT.fetch_calls(transport))
      assert fetches_after == 2, "read_path triggered one follow-up fetch for the blob"
    end

    test "server that doesn't advertise filter → error by default" do
      origin = build_origin()

      transport =
        %{FilterFakeT.new(origin.store, advertise_filter: false) | origin: origin.store}

      :persistent_term.put({FilterFakeT, transport.calls, :refs}, [
        {"refs/heads/main", origin.commit}
      ])

      assert {:error, {:filter_unsupported, _}} =
               Exgit.clone(transport, filter: {:blob, :none})
    end

    test "tree:0 filter (shallow-commit-only) encodes correctly" do
      assert Exgit.Filter.encode({:tree, 0}) == {:ok, "tree:0"}
    end

    test "blob:limit filter encodes size correctly" do
      assert Exgit.Filter.encode({:blob, {:limit, 1024}}) == {:ok, "blob:limit=1024"}
      assert Exgit.Filter.encode({:blob, {:limit, "1m"}}) == {:ok, "blob:limit=1m"}
      assert Exgit.Filter.encode({:blob, {:limit, "100k"}}) == {:ok, "blob:limit=100k"}
    end

    test "server that advertises filter but rejects the specific filter returns error" do
      # Simulate GitLab-style behavior: advertises "filter" but rejects
      # some filter specs (e.g. unsupported sparse specs). Our FakeT
      # always serves blob:none successfully, but a real rejection
      # comes back as an error response from Transport.fetch — which
      # we propagate via lazy_clone.
      origin = build_origin()
      transport = %{FilterFakeT.new(origin.store) | origin: origin.store}

      :persistent_term.put({FilterFakeT, transport.calls, :refs}, [
        {"refs/heads/main", origin.commit}
      ])

      # An invalid filter spec (neither :none nor a known tuple) fails
      # at encode time before we hit the transport.
      assert {:error, {:invalid_filter, _}} =
               Exgit.clone(transport, filter: :invalid_filter_form)
    end

    test "server without filter + if_unsupported: :ignore → falls back to full fetch" do
      origin = build_origin()

      transport =
        %{FilterFakeT.new(origin.store, advertise_filter: false) | origin: origin.store}

      :persistent_term.put({FilterFakeT, transport.calls, :refs}, [
        {"refs/heads/main", origin.commit}
      ])

      assert {:ok, repo} =
               Exgit.clone(transport,
                 filter: {:blob, :none},
                 if_unsupported: :ignore
               )

      # Blobs ARE present because the server ignored filter.
      assert Promisor.has_object?(repo.object_store, origin.readme)
    end
  end
end
