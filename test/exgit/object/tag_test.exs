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
      assert Tag.type(decoded) == "commit"
      assert Tag.tag(decoded) == "v1.0"
      assert Tag.tagger(decoded) == @tagger
      assert decoded.message == "release v1.0\n"
      assert decoded == tag
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
      assert Tag.tagger(decoded) == nil
      assert Tag.tag(decoded) == "v0.1"
    end
  end

  describe "byte-exact fidelity" do
    # Pinned against `git hash-object -t tag --literally`.
    @exotic_sha "738c8cfdfce431cfe7add4760aa61ebd5e1964d1"

    test "decode |> encode is byte-exact for a tag with unknown and multi-line headers" do
      raw =
        "object #{String.duplicate("a", 40)}\n" <>
          "type commit\n" <>
          "tag v9.9\n" <>
          "tagger #{@tagger}\n" <>
          "x-custom something unusual\n" <>
          "signature -----BEGIN PGP SIGNATURE-----\n" <>
          " abc123\n" <>
          " -----END PGP SIGNATURE-----\n" <>
          "\n" <>
          "Release with exotic headers\n"

      assert {:ok, tag} = Tag.decode(raw)

      # Unknown headers are preserved verbatim and in order; continuation
      # lines fold into the previous header's value with newlines.
      assert {"x-custom", "something unusual"} in tag.headers

      assert {"signature", "-----BEGIN PGP SIGNATURE-----\nabc123\n-----END PGP SIGNATURE-----"} in tag.headers

      assert Enum.map(tag.headers, &elem(&1, 0)) ==
               ["object", "type", "tag", "tagger", "x-custom", "signature"]

      # Re-encoding must reproduce the original bytes, so the SHA is stable.
      assert IO.iodata_to_binary(Tag.encode(tag)) == raw
      assert Tag.sha_hex(tag) == @exotic_sha
    end
  end

  describe "decode/1 validation" do
    test "missing required headers return errors" do
      assert {:error, {:missing_header, "object"}} = Tag.decode("type commit\ntag v1\n\nm\n")

      hex = String.duplicate("a", 40)
      assert {:error, {:missing_header, "type"}} = Tag.decode("object #{hex}\ntag v1\n\nm\n")
      assert {:error, {:missing_header, "tag"}} = Tag.decode("object #{hex}\ntype commit\n\nm\n")
    end
  end
end
