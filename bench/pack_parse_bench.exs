# Benchmark pack.parse against packs of varying size.
#
# Exercises the zlib-tracked-inflate hot path — the one the reviewer
# flagged as "O(log N) port round-trips per object, doesn't scale to
# Linux-sized packs."
#
#     mix run bench/pack_parse_bench.exs

alias Exgit.Object.Blob
alias Exgit.Pack.{Reader, Writer}

defmodule PackBench do
  def build_pack(num_objects, avg_size) do
    # Vary content per object so zlib actually does work.
    objects =
      for i <- 1..num_objects do
        # Alternate compressible vs incompressible content so the
        # pack is realistic-ish.
        body =
          if rem(i, 2) == 0 do
            :binary.copy("line #{i}\n", div(avg_size, 10))
          else
            :crypto.strong_rand_bytes(avg_size)
          end

        Blob.new(body)
      end

    {_elapsed, pack} = :timer.tc(fn -> Writer.build(objects) end)
    pack
  end

  def time_parse(pack, runs \\ 5) do
    times =
      for _ <- 1..runs do
        {us, {:ok, _}} = :timer.tc(fn -> Reader.parse(pack) end)
        us
      end

    sorted = Enum.sort(times)
    n = length(sorted)

    %{
      median: Enum.at(sorted, div(n, 2)),
      min: hd(sorted),
      max: List.last(sorted),
      mean: div(Enum.sum(sorted), n)
    }
  end

  def fmt(us) when us >= 1_000_000, do: :io_lib.format("~6.2f s", [us / 1_000_000]) |> to_string()
  def fmt(us) when us >= 1_000, do: :io_lib.format("~6.1f ms", [us / 1_000]) |> to_string()
  def fmt(us), do: "#{us} µs"

  def run do
    scenarios = [
      # {num_objects, avg_size_bytes, label}
      {100, 100, "100 tiny objects (10KB pack)"},
      {1_000, 1_000, "1K small objects (~1MB pack)"},
      {10_000, 1_000, "10K small objects (~10MB pack)"},
      {1_000, 10_000, "1K medium objects (~10MB pack)"},
      {100, 1_000_000, "100 big objects (~100MB pack)"}
    ]

    IO.puts("")
    IO.puts(String.pad_trailing("Scenario", 40) <> "pack size    median    min      objects/s")
    IO.puts(String.duplicate("-", 85))

    for {n, sz, label} <- scenarios do
      pack = build_pack(n, sz)
      pack_mb = Float.round(byte_size(pack) / 1_000_000, 2)
      stats = time_parse(pack)
      throughput = round(n * 1_000_000 / stats.median)

      IO.puts(
        String.pad_trailing(label, 40) <>
          String.pad_leading("#{pack_mb} MB", 9) <>
          "    " <>
          String.pad_leading(fmt(stats.median), 10) <>
          "  " <>
          String.pad_leading(fmt(stats.min), 8) <>
          "   " <>
          String.pad_leading("#{throughput}", 8)
      )
    end

    IO.puts("")
  end
end

PackBench.run()
