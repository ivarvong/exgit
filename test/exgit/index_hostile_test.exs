defmodule Exgit.IndexHostileTest do
  @moduledoc """
  Regression coverage for the Index audit round.

  Prior to this round, `Exgit.Index.parse/2` had:
    * no cap on `count` field (could be 2^32-1)
    * no cap on total input size
    * no trailing SHA-1 checksum verification

  A hostile `.git/index` could claim a billion entries, trigger a
  billion-iteration parse loop, or silently return corrupted data
  after a bit-flip. These tests assert the new guards trip
  correctly.
  """

  use ExUnit.Case, async: true

  alias Exgit.Index

  defp with_checksum(body) do
    body <> :crypto.hash(:sha, body)
  end

  describe "max_entries cap" do
    test "rejects count > cap" do
      # Valid header claiming 10 entries, but cap = 5.
      body = <<"DIRC", 2::32, 10::32>>
      data = with_checksum(body)

      assert {:error, {:too_many_entries, 10, 5}} =
               Index.parse(data, max_entries: 5)
    end

    test "default cap allows reasonable indexes" do
      body = <<"DIRC", 2::32, 0::32>>
      data = with_checksum(body)

      assert {:ok, %Index{}} = Index.parse(data)
    end

    test "refuses a hostile count near 2^32" do
      body = <<"DIRC", 2::32, 0xFFFF_FFFF::32>>
      data = with_checksum(body)

      assert {:error, {:too_many_entries, _, _}} = Index.parse(data)
    end
  end

  describe "max_bytes cap" do
    test "rejects an oversized input" do
      # 1 MB input vs 1 KB cap — rejected before any parse work.
      big = :binary.copy(<<0>>, 1_000_000)
      assert {:error, {:index_too_large, 1_000_000, 1024}} = Index.parse(big, max_bytes: 1024)
    end
  end

  describe "checksum verification" do
    test "detects a single-bit flip in the content" do
      # Valid empty index, then flip one bit in the header.
      body = <<"DIRC", 2::32, 0::32>>
      data = with_checksum(body)

      # Flip byte 4 (start of version field).
      <<prefix::binary-size(4), byte, suffix::binary>> = data
      corrupted = <<prefix::binary, Bitwise.bxor(byte, 0x01), suffix::binary>>

      # With verification: rejected.
      assert {:error, _} = Index.parse(corrupted)

      # Without verification: best-effort parse (may or may not
      # succeed depending on where the flip landed, but no
      # checksum error).
      result = Index.parse(corrupted, verify_checksum: false)
      refute match?({:error, :checksum_mismatch}, result)
    end

    test "validates a correctly-checksummed empty index" do
      body = <<"DIRC", 2::32, 0::32>>
      data = with_checksum(body)

      assert {:ok, %Index{version: 2, entries: []}} = Index.parse(data)
    end
  end

  describe "never raises" do
    test "on random bytes" do
      # This one's a smoke test; the decoder fuzz file covers the
      # property-based sweep. Here we just assert a couple of
      # hostile shapes don't raise.
      for _ <- 1..50 do
        bytes = :crypto.strong_rand_bytes(:rand.uniform(256))
        result = Index.parse(bytes)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end
end
