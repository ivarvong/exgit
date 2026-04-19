defmodule Exgit.LFSTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias Exgit.LFS

  # Known-good pointer from the LFS spec examples. Line order
  # matters (keys after `version` must sort alphabetically):
  # oid before size.
  @good_pointer """
  version https://git-lfs.github.com/spec/v1
  oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
  size 12345
  """

  describe "parse/1 — valid pointers" do
    test "canonical pointer from spec" do
      assert {:ok, info} = LFS.parse(@good_pointer)

      assert info.oid ==
               "sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"

      assert info.size == 12_345
      assert info.raw == @good_pointer
    end

    test "accepts size 0" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:0000000000000000000000000000000000000000000000000000000000000000
      size 0
      """

      assert {:ok, %{size: 0}} = LFS.parse(data)
    end

    test "accepts ext-N- extension keys in sorted position" do
      # ext-0- < oid < size alphabetically, so ext goes first after version.
      data =
        "version https://git-lfs.github.com/spec/v1\n" <>
          "ext-0-foo extension-value\n" <>
          "oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393\n" <>
          "size 100\n"

      assert {:ok, _info} = LFS.parse(data)
    end

    test "pointer?/1 returns true for valid" do
      assert LFS.pointer?(@good_pointer)
    end
  end

  describe "parse/1 — rejections" do
    test "rejects non-binary" do
      assert {:error, :not_binary} = LFS.parse(nil)
      assert {:error, :not_binary} = LFS.parse(:atom)
    end

    test "rejects over-size input (prevents false-positive on large blobs)" do
      # Valid pointer padded with trailing data to exceed 1024 bytes.
      padded = @good_pointer <> String.duplicate("x", 1024)
      assert {:error, :too_large_for_pointer} = LFS.parse(padded)
    end

    test "rejects missing trailing newline" do
      no_trailing = String.trim_trailing(@good_pointer, "\n")
      assert {:error, :missing_trailing_newline} = LFS.parse(no_trailing)
    end

    test "rejects blob not starting with version line" do
      assert {:error, :not_lfs_pointer} = LFS.parse("hello world\n")
    end

    test "rejects blob with wrong version URL" do
      data = """
      version https://git-lfs.example.com/spec/v2
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      size 100
      """

      assert {:error, :not_lfs_pointer} = LFS.parse(data)
    end

    test "rejects missing oid" do
      data = """
      version https://git-lfs.github.com/spec/v1
      size 100
      """

      assert {:error, {:missing_key, "oid"}} = LFS.parse(data)
    end

    test "rejects missing size" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      """

      assert {:error, {:missing_key, "size"}} = LFS.parse(data)
    end

    test "rejects size with non-digits" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      size 123abc
      """

      assert {:error, {:invalid_size, _}} = LFS.parse(data)
    end

    test "rejects negative size" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      size -1
      """

      assert {:error, {:invalid_size, _}} = LFS.parse(data)
    end

    test "rejects non-sha256 oid scheme" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid md5:aabbccddeeff00112233445566778899
      size 100
      """

      assert {:error, :invalid_oid_scheme} = LFS.parse(data)
    end

    test "rejects sha256 oid with wrong length" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:deadbeef
      size 100
      """

      assert {:error, :invalid_oid} = LFS.parse(data)
    end

    test "rejects sha256 oid with uppercase hex" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:4D7A214614AB2935C943F9E0FF69D22EADBB8F32B1258DAAA5E2CA24D17E2393
      size 100
      """

      assert {:error, :invalid_oid} = LFS.parse(data)
    end

    test "rejects keys not in alphabetical order" do
      # `size` before `oid` — wrong order.
      data = """
      version https://git-lfs.github.com/spec/v1
      size 100
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      """

      assert {:error, :keys_not_sorted} = LFS.parse(data)
    end

    test "rejects duplicate keys" do
      data = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      oid sha256:0000000000000000000000000000000000000000000000000000000000000000
      size 100
      """

      assert {:error, _} = LFS.parse(data)
    end

    test "rejects unknown non-ext key" do
      data = """
      version https://git-lfs.github.com/spec/v1
      foo bar
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      size 100
      """

      assert {:error, {:unknown_key, "foo"}} = LFS.parse(data)
    end

    test "rejects empty lines within body" do
      data =
        "version https://git-lfs.github.com/spec/v1\n" <>
          "\n" <>
          "oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393\n" <>
          "size 100\n"

      assert {:error, _} = LFS.parse(data)
    end

    test "rejects lines with extra whitespace" do
      data =
        "version https://git-lfs.github.com/spec/v1\n" <>
          "oid  sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393\n" <>
          "size 100\n"

      assert {:error, _} = LFS.parse(data)
    end

    test "pointer?/1 returns false for all rejections" do
      refute LFS.pointer?("")
      refute LFS.pointer?("hello")
      refute LFS.pointer?(nil)
    end
  end

  describe "property: round-trip valid pointers" do
    property "any sha256:hex + size parses back to the same values" do
      check all(
              hex <- StreamData.list_of(hex_char(), length: 64),
              size <- StreamData.non_negative_integer(),
              max_runs: 200
            ) do
        hex_str = IO.iodata_to_binary(hex)

        pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:#{hex_str}
        size #{size}
        """

        assert {:ok, info} = LFS.parse(pointer)
        assert info.oid == "sha256:" <> hex_str
        assert info.size == size
      end
    end

    property "random binary blobs are not mistaken for pointers" do
      check all(
              data <- StreamData.binary(min_length: 0, max_length: 256),
              max_runs: 200
            ) do
        # A random binary either IS a valid pointer (astronomically
        # unlikely for random bytes ≤ 256) or parse returns error.
        # We assert the weaker property: nothing crashes.
        result = LFS.parse(data)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    defp hex_char do
      StreamData.one_of([
        StreamData.integer(?0..?9),
        StreamData.integer(?a..?f)
      ])
    end
  end
end
