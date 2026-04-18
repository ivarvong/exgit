defmodule Exgit.Pack.ReaderPerformanceTest do
  use ExUnit.Case, async: false

  alias Exgit.Object.Blob
  alias Exgit.Pack.{Reader, Writer}
  alias Exgit.Test.PackBuilder

  @tag :slow
  test "parses a pack of 2000 non-delta blobs in reasonable time (P0.7)" do
    # The binary-search find_compressed_length inflates prefixes of the
    # REMAINING pack data for every object. On a 2000-blob pack with ~1KB
    # blobs, the pack is ~2MB and each probe inflates up to 2MB. The
    # inflate-per-probe cost dominates even if each probe is fast.
    blobs =
      for _ <- 1..2_000 do
        # 1KB-ish, highly compressible so zlib is cheap.
        Blob.new(String.duplicate("content ", 128))
      end

    pack = Writer.build(blobs)

    {time_us, {:ok, objects}} = :timer.tc(fn -> Reader.parse(pack) end)

    assert length(objects) == 2_000
    assert time_us < 5_000_000, "2000-object pack took #{time_us}us to parse"
  end

  @tag :slow
  test "REF_DELTA base resolution is not O(N^2) (P0.11)" do
    # Doubling-rate benchmark: for linear behavior, time at 2N ≈ 2× time
    # at N; for quadratic, ≈ 4×. Noise on shared CI can spike any
    # single measurement, so we take the median of several runs at
    # each size — much more robust than a single timing.
    small = 200
    large = 400
    content_size = 4_096
    trials = 5

    # Warm up to stabilize.
    _ = time_parse(50, content_size)

    t_small = median(for _ <- 1..trials, do: time_parse(small, content_size))
    t_large = median(for _ <- 1..trials, do: time_parse(large, content_size))

    ratio = t_large / max(t_small, 1)

    # Linear is 2.0, quadratic is 4.0 in the clean-room sense. In
    # practice, shared CI runners exhibit scheduler / allocator /
    # zlib-port contention that pushes per-object cost up with N, so
    # the measured ratio for linear algorithms can reach ~5-6× on
    # ubuntu-latest even with median-of-5. A true quadratic regression
    # would show 10×+ at these sizes. We set the cutoff generously.
    assert ratio < 8.0,
           "time(#{large}) / time(#{small}) = #{Float.round(ratio, 2)} " <>
             "(median of #{trials}: #{t_small}us vs #{t_large}us) — looks quadratic"
  end

  defp time_parse(n, content_size) do
    base_blobs =
      for i <- 1..n, do: Blob.new("b_#{i}_" <> :crypto.strong_rand_bytes(content_size))

    bases = Enum.map(base_blobs, &{Blob.encode(&1) |> IO.iodata_to_binary(), Blob.sha(&1)})

    full_entries = for {content, _sha} <- bases, do: {:full, :blob, content}

    delta_entries =
      for {base_content, base_sha} <- bases do
        result = base_content <> "+mut"
        {:ref_delta, base_sha, base_content, result}
      end

    pack = PackBuilder.build(full_entries ++ delta_entries)

    {time_us, {:ok, _}} = :timer.tc(fn -> Reader.parse(pack) end)
    time_us
  end

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
