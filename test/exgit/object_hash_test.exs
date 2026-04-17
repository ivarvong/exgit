defmodule Exgit.ObjectHashTest do
  use ExUnit.Case, async: true

  describe "streaming hash (P2.2)" do
    test "compute_sha yields the same SHA as the one-shot hash" do
      content = "hello world\n"
      type_str = "blob"

      streamed = Exgit.Object.compute_sha(type_str, content)

      expected =
        :crypto.hash(
          :sha,
          IO.iodata_to_binary(["blob", ?\s, Integer.to_string(byte_size(content)), 0, content])
        )

      assert streamed == expected
    end

    test "works for large content without OOM" do
      # 16MB blob — if compute_sha materialized the full bytestring
      # doubled, this would allocate 32MB+ which is still fine, but the
      # streaming implementation keeps memory close to input size.
      big = :crypto.strong_rand_bytes(16 * 1024 * 1024)

      {_, mem_before} = Process.info(self(), :memory)

      sha = Exgit.Object.compute_sha("blob", big)

      {_, mem_after} = Process.info(self(), :memory)

      # Sanity: sha is 20 bytes, and we didn't balloon by 2× the input.
      assert byte_size(sha) == 20

      # We're generous: peak process memory shouldn't grow by more than
      # 2× the input beyond the input itself. This catches gross leaks.
      # Note: this is a smoke test, not a strict SLA.
      assert mem_after - mem_before < byte_size(big) * 2,
             "memory grew by #{mem_after - mem_before} bytes for #{byte_size(big)}-byte input"
    end

    test "accepts arbitrary nested iodata" do
      sha_a = Exgit.Object.compute_sha("blob", ["a", ["b", [?c, "d"]], "e"])

      expected =
        :crypto.hash(
          :sha,
          IO.iodata_to_binary(["blob", ?\s, "5", 0, "abcde"])
        )

      assert sha_a == expected
    end
  end
end
