defmodule Exgit.Pack.WriterConcurrencyTest do
  @moduledoc """
  Stress test for `Pack.Writer.build/1` under concurrent invocation.

  The reviewer flagged pack-writer correctness under concurrent-clone
  scenarios as worth a stress test. `Pack.Writer.build/1` is a pure
  function — no ETS, no process state, no shared files — so in
  principle N concurrent builds of the same input should all
  produce byte-identical output. This test makes that promise
  explicit and would catch any future refactor that introduces
  shared state (e.g. a zlib port pool, an ETS cache).

  Also exercises `Pack.Reader.parse/1` round-trip under concurrency
  so a subtle state leak between deflate and inflate (shared port
  counter, etc.) shows up.
  """

  use ExUnit.Case, async: false
  @moduletag :slow

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.Pack.{Reader, Writer}

  defp make_objects(n) do
    for i <- 1..n do
      blob = Blob.new("blob content #{i}\n")
      tree = Tree.new([{"100644", "f#{i}.txt", Blob.sha(blob)}])

      commit =
        Commit.new(
          tree: Tree.sha(tree),
          parents: [],
          author: "A <a@a.com> 1700000000 +0000",
          committer: "A <a@a.com> 1700000000 +0000",
          message: "commit #{i}\n"
        )

      [blob, tree, commit]
    end
    |> List.flatten()
  end

  describe "concurrent build/1" do
    test "100 parallel builds of the same input produce identical bytes" do
      objects = make_objects(20)
      baseline = Writer.build(objects)

      results =
        1..100
        |> Enum.map(fn _ -> Task.async(fn -> Writer.build(objects) end) end)
        |> Task.await_many(30_000)

      # Every concurrent build must match the baseline byte-for-byte.
      # Divergence would indicate non-determinism (shared state,
      # unordered iteration, PID-dependent encoding, etc.).
      Enum.each(results, fn pack ->
        assert pack == baseline
      end)
    end

    test "100 parallel builds of DIFFERENT inputs round-trip cleanly" do
      # Each task builds a distinct object set and parses it back.
      # A leak between tasks would show up as either a parse error
      # (zlib state leaked) or a wrong object count (offsets
      # corrupted).
      results =
        1..100
        |> Enum.map(fn i ->
          Task.async(fn ->
            objects = make_objects(rem(i, 10) + 1)
            pack = Writer.build(objects)
            {:ok, parsed} = Reader.parse(pack)
            {length(objects), length(parsed)}
          end)
        end)
        |> Task.await_many(30_000)

      Enum.each(results, fn {built, parsed_count} ->
        assert built == parsed_count,
               "built #{built} objects but parsed back #{parsed_count}"
      end)
    end

    test "zlib ports are not leaked across 1000 builds" do
      # Each build opens + closes a zlib port via try/after. If the
      # cleanup ever regresses, the BEAM port table fills up after
      # ~64k invocations (default limit). Run enough to catch a
      # pathological leak without making the test painful.
      before_ports = length(:erlang.ports())

      for _ <- 1..1000 do
        _ = Writer.build([Blob.new("leak-check\n")])
      end

      # Give the GC a moment to collect any transient ports.
      :erlang.garbage_collect()
      after_ports = length(:erlang.ports())

      assert after_ports <= before_ports + 4,
             "port count grew from #{before_ports} to #{after_ports} over 1000 builds — leak suspected"
    end
  end
end
