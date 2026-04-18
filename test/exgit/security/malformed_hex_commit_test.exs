defmodule Exgit.Security.MalformedHexCommitTest do
  @moduledoc """
  Regression for review finding #23.

  A hostile remote can craft a commit object whose header block is
  syntactically well-formed but whose `tree`/`parent` values are NOT
  valid 40-char hex. Before the fix, `Commit.decode/1` accepted the
  commit and later accessor calls (`Commit.tree/1`, `Commit.parents/1`)
  raised `ArgumentError` deep inside `Base.decode16!/2`, DoSing any
  downstream walk, diff, push, or FS operation.

  The fix moves hex validation into `decode/1` so the error surfaces
  structurally as `{:error, {:invalid_hex_header, name, value}}` and
  the accessor path is infallible.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Commit

  describe "decode/1 rejects malformed hex" do
    test "tree header with non-hex bytes" do
      raw =
        "tree not-actually-hex-40-chars-long-xxxxxxxxx\n" <>
          "author Test <t@t.com> 1700000000 +0000\n" <>
          "committer Test <t@t.com> 1700000000 +0000\n" <>
          "\n" <>
          "msg\n"

      assert {:error, {:invalid_hex_header, "tree", _}} = Commit.decode(raw)
    end

    test "tree header with wrong length (not 40 chars)" do
      raw =
        "tree deadbeef\n" <>
          "author Test <t@t.com> 1700000000 +0000\n" <>
          "committer Test <t@t.com> 1700000000 +0000\n" <>
          "\n" <>
          "msg\n"

      assert {:error, {:invalid_hex_header, "tree", _}} = Commit.decode(raw)
    end

    test "parent header with non-hex bytes" do
      valid_hex = String.duplicate("a", 40)

      raw =
        "tree #{valid_hex}\n" <>
          "parent not-hex\n" <>
          "author Test <t@t.com> 1700000000 +0000\n" <>
          "committer Test <t@t.com> 1700000000 +0000\n" <>
          "\n" <>
          "msg\n"

      assert {:error, {:invalid_hex_header, "parent", _}} = Commit.decode(raw)
    end

    test "accessors are infallible on decoded commits" do
      # With the fix in place, every commit that decodes successfully
      # has valid hex headers, so these calls must never raise.
      valid_hex = String.duplicate("a", 40)

      raw =
        "tree #{valid_hex}\n" <>
          "parent #{valid_hex}\n" <>
          "author Test <t@t.com> 1700000000 +0000\n" <>
          "committer Test <t@t.com> 1700000000 +0000\n" <>
          "\n" <>
          "msg\n"

      assert {:ok, commit} = Commit.decode(raw)

      # These must not raise — that was the DoS vector.
      assert is_binary(Commit.tree(commit))
      assert byte_size(Commit.tree(commit)) == 20
      assert [parent] = Commit.parents(commit)
      assert byte_size(parent) == 20
    end
  end
end
