defmodule Exgit.Pack.IndexLookupTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Exgit.Pack.Index

  describe "lookup correctness (P0.10)" do
    test "finds entries at various fanout positions" do
      # Build entries spread across different fanout buckets.
      entries =
        for b <- [0x00, 0x01, 0x42, 0x7F, 0x80, 0xFE, 0xFF] do
          sha = <<b>> <> :binary.copy(<<b>>, 19)
          {sha, b * 7, b * 11}
        end

      pack_checksum = :binary.copy(<<0>>, 20)
      idx = Index.write(entries, pack_checksum)

      for {sha, _crc, offset} <- entries do
        assert {:ok, ^offset} = Index.lookup(idx, sha),
               "missed lookup for sha=#{Base.encode16(sha, case: :lower)}"
      end

      # Lookups for absent SHAs return :error.
      assert :error == Index.lookup(idx, :binary.copy(<<0xAB>>, 20))
    end

    test "binary search correctness: dense fanout bucket" do
      # 256 shas all with first byte 0x42 — forces lookup inside one
      # fanout bucket.
      entries =
        for i <- 0..255 do
          sha = <<0x42, i>> <> :binary.copy(<<i>>, 18)
          {sha, i, i * 100}
        end

      pack_checksum = :binary.copy(<<0>>, 20)
      idx = Index.write(entries, pack_checksum)

      for {sha, _, offset} <- entries do
        assert {:ok, ^offset} = Index.lookup(idx, sha)
      end
    end
  end

  describe "lookup performance (P0.10)" do
    @tag :slow
    test "lookup of N items is O(log N), not O(N)" do
      # Hardware-agnostic asymptotic check: measure lookup time at two
      # different N and assert the ratio is sub-linear.
      #
      # For binary search (O(log N)), doubling N adds ~1 comparison per
      # lookup — the time ratio stays near 1.0. For a linear scan
      # (O(N)), doubling N doubles the work. We compare N=8k vs N=32k
      # (4× size), so linear would give ~4.0 ratio; log-N gives ~1.15.
      #
      # Cutoff at 3.0 (midway between log-N and linear). Catches any
      # linear regression while tolerating GitHub runner jitter on
      # microsecond-scale timings — we observed ratios of 2.29 on
      # otherwise-clean runs due to noisy-neighbor scheduling.

      # Warmup — pay JIT + cache costs before the measured run.
      _ = time_lookups(2_000, 500)

      small_n = 8_000
      large_n = 32_000
      samples = 2_000

      t_small = time_lookups(small_n, samples)
      t_large = time_lookups(large_n, samples)

      ratio = t_large / max(t_small, 1)

      assert ratio < 3.0,
             "ratio=#{Float.round(ratio, 2)} " <>
               "(#{samples} lookups: #{t_small}us @ N=#{small_n}, " <>
               "#{t_large}us @ N=#{large_n}) — looks linear, not logarithmic"
    end
  end

  defp time_lookups(n, samples) do
    entries =
      for i <- 0..(n - 1) do
        # Spread over all 256 fanout buckets deterministically.
        sha =
          <<rem(i, 256)>> <>
            :binary.copy(<<div(i, 256)>>, 1) <>
            :binary.copy(<<i &&& 0xFF>>, 18)

        {sha, i, i * 1000}
      end

    pack_checksum = :binary.copy(<<0>>, 20)
    idx = Index.write(entries, pack_checksum)

    step = max(div(n, samples), 1)

    sample =
      entries
      |> Enum.take_every(step)
      |> Enum.take(samples)

    {time_us, _} =
      :timer.tc(fn ->
        for {sha, _, _} <- sample do
          {:ok, _} = Index.lookup(idx, sha)
        end
      end)

    time_us
  end
end
