defmodule Exgit.Object.BlobTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.Object.Blob
  import Exgit.Test.GitHelper

  describe "new/1" do
    test "creates a blob" do
      blob = Blob.new("hello world")
      assert blob.data == "hello world"
    end
  end

  describe "encode/decode round-trip" do
    test "round-trips" do
      blob = Blob.new("hello world\n")
      encoded = Blob.encode(blob)
      assert {:ok, decoded} = Blob.decode(encoded)
      assert decoded.data == blob.data
    end

    property "round-trips arbitrary binaries" do
      check all(data <- binary()) do
        blob = Blob.new(data)
        assert {:ok, decoded} = Blob.decode(Blob.encode(blob))
        assert decoded.data == data
      end
    end
  end

  describe "sha/1" do
    test "matches git hash-object for 'hello world'" do
      blob = Blob.new("hello world\n")
      assert Blob.sha_hex(blob) == "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"
    end

    test "matches git hash-object for empty blob" do
      blob = Blob.new("")
      assert Blob.sha_hex(blob) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
    end

    @tag :git_cross_check
    test "matches git hash-object for random content" do
      data = "test content for git cross-check\n"
      blob = Blob.new(data)
      our_sha = Blob.sha_hex(blob)

      {git_sha, 0} = cmd_with_stdin("git", ["hash-object", "--stdin"], data)
      assert our_sha == String.trim(git_sha)
    end
  end
end
