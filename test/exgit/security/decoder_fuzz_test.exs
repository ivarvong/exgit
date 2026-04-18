defmodule Exgit.Security.DecoderFuzzTest do
  @moduledoc """
  Property-based fuzz corpus for every object/pack/config decoder.

  The reviewer explicitly called out "explicit fuzz-corpus regression
  cases for every finding on this list" as a v1.0 requirement. This
  module exercises the `never raises on untrusted input, always
  returns a tagged tuple` contract every decoder's moduledoc
  promises.

  If a future change accidentally reintroduces a `raise` on the
  decode path, one of these properties will catch it.

  Decoders covered:
    * `Exgit.Object.Blob.decode/1`
    * `Exgit.Object.Tree.decode/1`
    * `Exgit.Object.Commit.decode/1`
    * `Exgit.Object.Tag.decode/1`
    * `Exgit.Pack.Reader.parse/2`
    * `Exgit.Config.parse/1` (already covered in ConfigFuzzTest)

  Each property runs at least 500 cases per invocation.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.Object.{Blob, Commit, Tag, Tree}
  alias Exgit.Pack.Reader

  @max_runs 500

  # Generator: random bytes up to 4 KiB. Covers enough surface to
  # trip off-by-one / length-prefix / varint bugs without making
  # the suite slow.
  defp random_bytes(max \\ 4096), do: StreamData.binary(max_length: max)

  # Generator: bytes biased toward looking like a tree. Helps
  # exercise the validation rules in Tree.decode/1 that catch
  # `..`, `/`, `.git`, etc.
  defp tree_like do
    StreamData.bind(StreamData.integer(0..20), fn n_entries ->
      StreamData.list_of(
        StreamData.tuple({
          StreamData.one_of([
            StreamData.constant("100644"),
            StreamData.constant("100755"),
            StreamData.constant("40000"),
            StreamData.constant("120000"),
            StreamData.constant("160000"),
            StreamData.binary(length: 6)
          ]),
          StreamData.binary(max_length: 32),
          StreamData.binary(length: 20)
        }),
        length: n_entries
      )
    end)
    |> StreamData.map(fn entries ->
      for {mode, name, sha} <- entries, into: <<>> do
        [mode, ?\s, name, 0, sha] |> IO.iodata_to_binary()
      end
    end)
  end

  describe "Blob.decode/1 never raises" do
    property "on random bytes" do
      check all(bytes <- random_bytes(), max_runs: @max_runs) do
        result = Blob.decode(bytes)
        assert match?({:ok, %Blob{}}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "Tree.decode/1 never raises" do
    property "on random bytes" do
      check all(bytes <- random_bytes(), max_runs: @max_runs) do
        result = Tree.decode(bytes)
        assert match?({:ok, %Tree{}}, result) or match?({:error, _}, result)
      end
    end

    property "on tree-shaped bytes" do
      check all(bytes <- tree_like(), max_runs: @max_runs) do
        result = Tree.decode(bytes)
        assert match?({:ok, %Tree{}}, result) or match?({:error, _}, result)
      end
    end

    property "rejected entries are structurally safe even in accepted trees" do
      check all(bytes <- tree_like(), max_runs: @max_runs) do
        case Tree.decode(bytes) do
          {:ok, %Tree{entries: entries}} ->
            # Every entry name that made it through MUST NOT contain
            # `/`, NUL, be `.`, be `..`, or be empty. If any does,
            # the validator let something through it shouldn't have.
            for {_mode, name, _sha} <- entries do
              refute name == ""
              refute name == "."
              refute name == ".."
              refute String.contains?(name, "/")
              refute String.contains?(name, <<0>>)
              refute String.downcase(name) == ".git"
              refute String.downcase(name) == ".gitmodules"
            end

          {:error, _} ->
            :ok
        end
      end
    end
  end

  describe "Commit.decode/1 never raises" do
    property "on random bytes" do
      check all(bytes <- random_bytes(), max_runs: @max_runs) do
        result = Commit.decode(bytes)
        assert match?({:ok, %Commit{}}, result) or match?({:error, _}, result)
      end
    end

    property "accepted commits have infallible accessors" do
      check all(bytes <- random_bytes(), max_runs: @max_runs) do
        case Commit.decode(bytes) do
          {:ok, commit} ->
            # These must not raise. If decode accepted the commit,
            # its hex headers must have been validated.
            assert is_binary(Commit.tree(commit))
            assert byte_size(Commit.tree(commit)) == 20
            assert is_list(Commit.parents(commit))

            for parent <- Commit.parents(commit) do
              assert is_binary(parent)
              assert byte_size(parent) == 20
            end

          {:error, _} ->
            :ok
        end
      end
    end
  end

  describe "Tag.decode/1 never raises" do
    property "on random bytes" do
      check all(bytes <- random_bytes(), max_runs: @max_runs) do
        result = Tag.decode(bytes)
        assert match?({:ok, %Tag{}}, result) or match?({:error, _}, result)
      end
    end

    property "accepted tags have 20-byte object sha" do
      check all(bytes <- random_bytes(), max_runs: @max_runs) do
        case Tag.decode(bytes) do
          {:ok, tag} ->
            assert is_binary(tag.object)
            assert byte_size(tag.object) == 20

          {:error, _} ->
            :ok
        end
      end
    end
  end

  describe "Pack.Reader.parse/2 never raises" do
    property "on random bytes (header-ish and otherwise)" do
      # Cap at 64KB so we don't spend forever on random inputs.
      check all(bytes <- StreamData.binary(max_length: 65_536), max_runs: @max_runs) do
        # Explicit low caps so a hostile giant-object header can't
        # make a single property iteration slow.
        result = Reader.parse(bytes, max_object_bytes: 1_000_000, max_resolved_bytes: 10_000_000)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    property "on PACK-prefixed bytes (common near-misses)" do
      check all(
              suffix <- StreamData.binary(max_length: 4096),
              n <- StreamData.integer(0..10),
              max_runs: @max_runs
            ) do
        header = <<"PACK"::binary, 2::32-big, n::32-big>>

        result =
          Reader.parse(header <> suffix,
            max_object_bytes: 1_000_000,
            max_resolved_bytes: 10_000_000
          )

        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end
end
