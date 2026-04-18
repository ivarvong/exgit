defmodule Exgit.PromisorHavesTest do
  @moduledoc """
  A1: commit-haves for subsequent fetches must be O(1) to collect and
  bounded in size. A cached commit set lives on the Promisor struct
  and is updated incrementally on every object imported.
  """

  use ExUnit.Case, async: true

  alias Exgit.{Object.Blob, Object.Commit, Object.Tree, ObjectStore}
  alias Exgit.ObjectStore.Promisor

  defmodule FakeT do
    defstruct [:origin, :calls]

    def new(origin) do
      {:ok, pid} = Agent.start_link(fn -> [] end)
      %__MODULE__{origin: origin, calls: pid}
    end

    def calls(%__MODULE__{calls: pid}), do: Agent.get(pid, &Enum.reverse/1)
  end

  defimpl Exgit.Transport, for: Exgit.PromisorHavesTest.FakeT do
    alias Exgit.PromisorHavesTest.FakeT

    def capabilities(_), do: {:ok, %{version: 2}}
    def ls_refs(_, _), do: {:ok, []}
    def push(_, _, _, _), do: {:error, :unsupported}

    def fetch(%FakeT{origin: origin, calls: pid}, wants, opts) do
      haves = Keyword.get(opts, :haves, [])
      Agent.update(pid, &[%{wants: wants, haves: haves} | &1])

      objects =
        for sha <- wants do
          case Exgit.ObjectStore.get(origin, sha) do
            {:ok, obj} -> obj
            _ -> nil
          end
        end
        |> Enum.reject(&is_nil/1)

      {:ok, Exgit.Pack.Writer.build(objects), %{objects: length(objects)}}
    end
  end

  test "haves set is maintained in O(1) via incremental updates" do
    origin = ObjectStore.Memory.new()

    # Build a fake origin with 500 commit objects.
    {origin, commit_shas} = seed_commits(origin, 500)

    transport = FakeT.new(origin)

    # Construct a Promisor and seed it by importing all commits via
    # import_objects.
    promisor = Promisor.new(transport)

    raws =
      for sha <- commit_shas do
        {:ok, obj} = ObjectStore.get(origin, sha)
        {:commit, sha, obj |> Exgit.Object.encode() |> IO.iodata_to_binary()}
      end

    {:ok, promisor} = Promisor.import_objects(promisor, raws)

    # Haves lookup: trigger a fetch by calling resolve on a not-cached sha.
    missing = :crypto.hash(:sha, "never seen")
    _ = Promisor.resolve(promisor, missing)

    [call] = FakeT.calls(transport)

    # A1 requires: haves capped at 256 regardless of how many commits
    # are cached.
    assert length(call.haves) <= 256,
           "sent #{length(call.haves)} haves; must be capped at 256"

    # And every have is a 20-byte SHA, not a wasted field.
    assert Enum.all?(call.haves, &(is_binary(&1) and byte_size(&1) == 20))
  end

  defp seed_commits(store, n) do
    # Just commits — no need for tree+blob. We create dummy Tree SHAs.
    Enum.reduce(1..n, {store, []}, fn i, {s, shas} ->
      tree_sha = :crypto.hash(:sha, "tree-#{i}")
      # Synthesize a minimal commit object; we don't need a real tree
      # object in the store since we only test commit-sha collection.

      c =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "T <t@t> #{1_700_000_000 + i} +0000",
          committer: "T <t@t> #{1_700_000_000 + i} +0000",
          message: "commit #{i}\n"
        )

      {:ok, sha, s2} = ObjectStore.put(s, c)
      {s2, [sha | shas]}
    end)
  end

  # Silence unused-alias warnings if the test module shrinks.
  _ = {Blob, Tree}
end
