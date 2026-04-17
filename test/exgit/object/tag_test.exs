defmodule Exgit.Object.TagTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Tag

  @tagger "Test User <test@example.com> 1000000000 +0000"

  describe "encode/decode round-trip" do
    test "round-trips an annotated tag" do
      obj_sha = :crypto.hash(:sha, "commit")

      tag =
        Tag.new(
          object: obj_sha,
          type: "commit",
          tag: "v1.0",
          tagger: @tagger,
          message: "release v1.0\n"
        )

      encoded = tag |> Tag.encode() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Tag.decode(encoded)
      assert decoded.object == obj_sha
      assert decoded.type == "commit"
      assert decoded.tag == "v1.0"
      assert decoded.tagger == @tagger
      assert decoded.message == "release v1.0\n"
    end

    test "round-trips a tag without tagger" do
      obj_sha = :crypto.hash(:sha, "commit")

      tag =
        Tag.new(
          object: obj_sha,
          tag: "v0.1",
          message: "early\n"
        )

      encoded = tag |> Tag.encode() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Tag.decode(encoded)
      assert decoded.tagger == nil
      assert decoded.tag == "v0.1"
    end
  end
end
