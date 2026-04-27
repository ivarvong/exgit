defmodule Exgit.FSPrefetchHistoryStreamingTest do
  # Regression: prefetch_history must pass `object_store: promisor` to
  # `Transport.fetch` so the HTTP transport routes pack bytes through
  # the StreamParser path. If the opt is dropped, http.ex falls back
  # to the buffered iolist path and OOMs on large commit graphs (e.g.
  # linux, esp-idf). The bug is silent on small repos.
  #
  # We use a recording Transport double — the streaming code path
  # itself is exercised by the http_streaming_test.exs suite. This
  # test isolates the contract between FS and Transport.
  use ExUnit.Case, async: true

  alias Exgit.{FS, Object, RefStore, Repository}
  alias Exgit.Object.Commit
  alias Exgit.ObjectStore.Promisor

  defmodule RecordingT do
    defstruct [:agent]

    def new do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      %__MODULE__{agent: agent}
    end

    def calls(%__MODULE__{agent: agent}), do: Agent.get(agent, &Enum.reverse/1)
  end

  defimpl Exgit.Transport, for: Exgit.FSPrefetchHistoryStreamingTest.RecordingT do
    alias Exgit.FSPrefetchHistoryStreamingTest.RecordingT

    def capabilities(_), do: {:ok, %{version: 2}}
    def ls_refs(_, _), do: {:ok, [], %{}}
    def push(_, _, _, _), do: {:error, :unsupported}

    def fetch(%RecordingT{agent: agent}, wants, opts) do
      Agent.update(agent, &[%{wants: wants, opts: opts} | &1])

      # Mirror the streaming-success return shape so prefetch_history
      # threads the (claimed) updated promisor forward without taking
      # the buffered-pack branch.
      store = Keyword.get(opts, :object_store)
      {:ok, <<>>, %{objects: 0, store: store}}
    end
  end

  test "prefetch_history routes Transport.fetch through the streaming path" do
    commit =
      Commit.new(
        tree: :crypto.hash(:sha, "fake-tree"),
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "head\n"
      )

    head_sha = Object.sha(commit)
    raw = commit |> Object.encode() |> IO.iodata_to_binary()

    transport = RecordingT.new()
    promisor = Promisor.new(transport)
    {:ok, promisor} = Promisor.import_objects(promisor, [{:commit, head_sha, raw}])

    {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", head_sha, [])
    {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = %Repository{
      object_store: promisor,
      ref_store: rs,
      config: Exgit.Config.new(),
      path: nil
    }

    assert {:ok, _new_repo} = FS.prefetch_history(repo, "HEAD")

    [call] = RecordingT.calls(transport)

    # The contract: object_store: must be in opts. Without it, the http
    # transport buffers the full pack in memory before parsing.
    assert Keyword.has_key?(call.opts, :object_store),
           "prefetch_history did not pass object_store: to Transport.fetch — " <>
             "streaming path will not be taken on the HTTP transport"

    # And it must be the Promisor itself — the StreamParser writes
    # objects through the store handed in here.
    assert call.opts[:object_store] == promisor,
           "object_store: must be the Promisor used by the Repository"

    # History-only filter is also part of the contract; without it the
    # server may send blob content we don't need.
    assert call.opts[:filter] == "blob:none",
           "prefetch_history must request filter: blob:none"

    # And no haves (this is a prefetch, not an incremental update).
    assert call.opts[:haves] == []

    # The wants set must be the resolved HEAD commit SHA.
    assert call.wants == [head_sha]
  end

  test "prefetch_history is a no-op on non-Promisor stores (no Transport.fetch call)" do
    # Memory-backed store: prefetch_history short-circuits without
    # calling any transport. Verifies the Promisor-only guard hasn't
    # regressed (otherwise plain Memory repos would crash trying to
    # call fetch on a nil transport).
    transport = RecordingT.new()

    commit =
      Commit.new(
        tree: :crypto.hash(:sha, "fake-tree"),
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "head\n"
      )

    {:ok, head_sha, store} = Exgit.ObjectStore.put(Exgit.ObjectStore.Memory.new(), commit)
    {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", head_sha, [])
    {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = %Repository{
      object_store: store,
      ref_store: rs,
      config: Exgit.Config.new(),
      path: nil
    }

    assert {:ok, ^repo} = FS.prefetch_history(repo, "HEAD")
    assert RecordingT.calls(transport) == []
  end
end
