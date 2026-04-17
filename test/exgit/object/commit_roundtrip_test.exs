defmodule Exgit.Object.CommitRoundtripTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Commit

  describe "decode |> encode is byte-exact (P0.3)" do
    test "simple commit without signature round-trips" do
      # A canonical commit object (no signature).
      raw =
        "tree " <>
          String.duplicate("0", 40) <>
          "\n" <>
          "parent " <>
          String.duplicate("1", 40) <>
          "\n" <>
          "author Alice <a@example.com> 1700000000 +0000\n" <>
          "committer Alice <a@example.com> 1700000000 +0000\n" <>
          "\n" <>
          "first line\n\nbody text\n"

      {:ok, commit} = Commit.decode(raw)
      assert IO.iodata_to_binary(Commit.encode(commit)) == raw
    end

    test "commit with gpgsig BEFORE committer is byte-preserved" do
      # Real-world commits can have arbitrary header ordering. The canonical
      # form emitted by `git commit -S` places gpgsig AFTER committer but
      # the Git protocol considers header order part of the object's bytes
      # for SHA purposes — so we must preserve what we read.
      raw =
        "tree " <>
          String.duplicate("0", 40) <>
          "\n" <>
          "parent " <>
          String.duplicate("1", 40) <>
          "\n" <>
          "author Alice <a@example.com> 1700000000 +0000\n" <>
          "gpgsig -----BEGIN PGP SIGNATURE-----\n" <>
          " Version: GnuPG v2\n" <>
          " \n" <>
          " xyzxyz\n" <>
          " -----END PGP SIGNATURE-----\n" <>
          "committer Alice <a@example.com> 1700000000 +0000\n" <>
          "\n" <>
          "signed commit\n"

      {:ok, commit} = Commit.decode(raw)
      re_encoded = IO.iodata_to_binary(Commit.encode(commit))

      assert re_encoded == raw,
             "round-trip mismatch:\n\nexpected:\n#{inspect(raw)}\n\ngot:\n#{inspect(re_encoded)}"
    end

    test "commit with extra/unknown headers is byte-preserved" do
      # Git allows (and sometimes writes) additional headers such as
      # 'mergetag' or 'encoding' or custom ones. Preserving them verbatim
      # is required for SHA stability.
      raw =
        "tree " <>
          String.duplicate("a", 40) <>
          "\n" <>
          "parent " <>
          String.duplicate("b", 40) <>
          "\n" <>
          "author Alice <a@example.com> 1700000000 +0000\n" <>
          "committer Alice <a@example.com> 1700000000 +0000\n" <>
          "encoding UTF-8\n" <>
          "HG:rename source\n" <>
          "\n" <>
          "hello\n"

      {:ok, commit} = Commit.decode(raw)
      assert IO.iodata_to_binary(Commit.encode(commit)) == raw
    end

    test "commit with multiple parents preserves order" do
      raw =
        "tree " <>
          String.duplicate("0", 40) <>
          "\n" <>
          "parent " <>
          String.duplicate("1", 40) <>
          "\n" <>
          "parent " <>
          String.duplicate("2", 40) <>
          "\n" <>
          "parent " <>
          String.duplicate("3", 40) <>
          "\n" <>
          "author Alice <a@example.com> 1700000000 +0000\n" <>
          "committer Alice <a@example.com> 1700000000 +0000\n" <>
          "\n" <>
          "octopus\n"

      {:ok, commit} = Commit.decode(raw)
      assert IO.iodata_to_binary(Commit.encode(commit)) == raw
    end
  end

  describe "decode rejects malformed headers" do
    test "continuation line with no preceding header is an error" do
      raw =
        " continuation-first\n" <>
          "tree " <>
          String.duplicate("0", 40) <>
          "\n" <>
          "author Alice <a@example.com> 1700000000 +0000\n" <>
          "committer Alice <a@example.com> 1700000000 +0000\n" <>
          "\n" <>
          "hi\n"

      assert {:error, _} = Commit.decode(raw)
    end
  end

  describe "author parent list performance (P2.4)" do
    @tag :slow
    test "decode of a commit with many parents is not O(n^2)" do
      n = 500

      raw =
        "tree " <>
          String.duplicate("0", 40) <>
          "\n" <>
          for _ <- 1..n, into: "" do
            "parent " <> String.duplicate("1", 40) <> "\n"
          end <>
          "author Alice <a@example.com> 1700000000 +0000\n" <>
          "committer Alice <a@example.com> 1700000000 +0000\n" <>
          "\n" <>
          "big\n"

      {time_us, {:ok, commit}} = :timer.tc(fn -> Commit.decode(raw) end)

      assert length(Commit.parents(commit)) == n
      # Generous bound — a non-quadratic decode of 500 parents should be
      # well under a second.
      assert time_us < 1_000_000
    end
  end
end
