defmodule Exgit.Security.TagMalformedHexTest do
  @moduledoc """
  Sibling to the commit-malformed-hex regression: `Tag.decode/1`
  must validate the `object` header as 40-char hex and return an
  error rather than raising via `Hex.decode!/1`.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Tag

  test "tag with non-hex object header returns an error tuple" do
    raw =
      "object not-actually-hex-40-chars-long-xxxxxxxxx\n" <>
        "type commit\n" <>
        "tag v1.0.0\n" <>
        "tagger Test <t@t.com> 1700000000 +0000\n" <>
        "\n" <>
        "Release notes\n"

    assert {:error, {:invalid_hex_header, "object", _}} = Tag.decode(raw)
  end

  test "tag with wrong-length object header is rejected" do
    raw =
      "object deadbeef\n" <>
        "type commit\n" <>
        "tag v1.0.0\n" <>
        "\n" <>
        "msg\n"

    assert {:error, {:invalid_hex_header, "object", _}} = Tag.decode(raw)
  end

  test "valid tag decodes correctly" do
    hex = String.duplicate("a", 40)

    raw =
      "object #{hex}\n" <>
        "type commit\n" <>
        "tag v1.0.0\n" <>
        "\n" <>
        "msg\n"

    assert {:ok, tag} = Tag.decode(raw)
    assert byte_size(tag.object) == 20
  end
end
