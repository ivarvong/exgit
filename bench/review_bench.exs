# Benchmark harness for the lazy-clone + prefetch + grep workflow
# across fixtures of varying size. Each fixture is a real public
# GitHub repo, so the numbers reflect network + real git server
# behavior, not a synthetic replay.
#
#     mix run bench/review_bench.exs             # default 30 runs each
#     mix run bench/review_bench.exs 10          # 10 runs each
#     mix run bench/review_bench.exs 30 pyex     # just the pyex fixture
#
# Fixtures (size ascending):
#
#   pyex            275 files    ~1.2 MB pack   owned, stable
#   cloudflare/agents  ~1400 files  ~4 MB pack   medium real-world
#   anomalyco/opencode ~4600 files  ~30 MB pack  large, grep-perf
#
# Report shape: median / p95 / min / max per phase, plus per-event
# telemetry durations.

{runs, filter} =
  case System.argv() do
    [] -> {30, :all}
    [n] -> {String.to_integer(n), :all}
    [n, name] -> {String.to_integer(n), String.to_atom(name)}
    _ -> {30, :all}
  end

fixtures = [
  {:pyex, "https://github.com/ivarvong/pyex"},
  {:agents, "https://github.com/cloudflare/agents"},
  {:opencode, "https://github.com/anomalyco/opencode"}
]

fixtures =
  case filter do
    :all -> fixtures
    name -> Enum.filter(fixtures, fn {n, _} -> n == name end)
  end

defmodule Collector do
  @moduledoc false
  def new, do: :ets.new(:bench_events, [:public, :bag])

  def attach(table) do
    :telemetry.attach_many(
      "bench-#{:erlang.unique_integer([:positive])}",
      [
        [:exgit, :transport, :ls_refs, :stop],
        [:exgit, :transport, :fetch, :stop],
        [:exgit, :pack, :parse, :stop],
        [:exgit, :object_store, :get, :stop],
        [:exgit, :fs, :walk, :stop],
        [:exgit, :fs, :grep, :stop]
      ],
      fn event, measurements, _metadata, table ->
        us = System.convert_time_unit(measurements.duration, :native, :microsecond)
        :ets.insert(table, {event, us})
      end,
      table
    )
  end

  def durations(table, event) do
    :ets.match_object(table, {event, :_})
    |> Enum.map(fn {_, us} -> us end)
  end

  def reset(table) do
    :ets.delete_all_objects(table)
  end
end

defmodule Stats do
  @moduledoc false
  def summarize([]), do: %{median: 0, p95: 0, min: 0, max: 0, n: 0}

  def summarize(nums) do
    sorted = Enum.sort(nums)
    n = length(sorted)

    %{
      median: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, min(n - 1, trunc(n * 0.95))),
      min: hd(sorted),
      max: List.last(sorted),
      n: n
    }
  end

  def fmt(us) when is_integer(us) do
    cond do
      us >= 1_000_000 -> :io_lib.format("~.2f s", [us / 1_000_000])
      us >= 1_000 -> :io_lib.format("~.1f ms", [us / 1_000])
      true -> :io_lib.format("~B us", [us])
    end
    |> IO.iodata_to_binary()
    |> to_string()
    |> String.pad_leading(10)
  end
end

defmodule Run do
  @moduledoc false

  # One benchmark iteration of the "clone, prefetch once, then grep
  # many times" workflow — which matches how an agent actually uses
  # this library: pay the prefetch cost once, amortize across many
  # reads. Returns per-phase timings where `grep` is the MEDIAN of
  # `grep_runs` grep calls against the same warm repo.
  @grep_runs 5

  def one(url, run_idx) do
    {t_clone, {:ok, repo}} = :timer.tc(fn -> Exgit.clone(url, lazy: true) end)

    {t_prefetch, {:ok, repo}} =
      :timer.tc(fn -> Exgit.FS.prefetch(repo, "HEAD", blobs: true) end)

    # Warm up: the first grep triggers an on-demand commit fetch
    # (the cache doesn't have the commit after lazy-clone +
    # prefetch, which only pulls the tree reachable from HEAD, not
    # HEAD's commit object itself). After this first call, the
    # commit is cached and subsequent greps are pure local work.
    {t_grep_first, first_results} =
      :timer.tc(fn ->
        Exgit.FS.grep(repo, "HEAD", "anthropic", case_insensitive: true)
        |> Enum.to_list()
      end)

    # Warm greps: take the median of a handful of runs so we
    # measure steady-state grep, not the first-grep tax.
    grep_times =
      for _ <- 1..@grep_runs do
        {us, _} =
          :timer.tc(fn ->
            Exgit.FS.grep(repo, "HEAD", "anthropic", case_insensitive: true)
            |> Enum.to_list()
          end)

        us
      end

    t_grep_warm = grep_times |> Enum.sort() |> Enum.at(div(@grep_runs, 2))

    %{
      lazy_clone: t_clone,
      prefetch: t_prefetch,
      grep_first: t_grep_first,
      grep_warm: t_grep_warm,
      total: t_clone + t_prefetch + t_grep_first,
      match_count: length(first_results),
      run: run_idx
    }
  end
end

defmodule Report do
  @moduledoc false
  def header(label) do
    IO.puts("")
    IO.puts("========================================")
    IO.puts(label)
    IO.puts("========================================\n")
  end

  def phase_table(results, runs) do
    IO.puts(
      "#{String.pad_trailing("Phase", 35)}" <>
        "#{String.pad_leading("median", 12)}" <>
        "#{String.pad_leading("p95", 12)}" <>
        "#{String.pad_leading("min", 12)}" <>
        "#{String.pad_leading("max", 12)}"
    )

    IO.puts(String.duplicate("-", 83))

    for {phase, label} <- [
          {:lazy_clone, "1. clone(url, lazy: true)"},
          {:prefetch, "2. prefetch(blobs: true)"},
          {:grep_first, "3a. grep (first / cold)"},
          {:grep_warm, "3b. grep (warm, median of 5)"},
          {:total, "   total (1 + 2 + 3a)"}
        ] do
      stats = results |> Enum.map(& &1[phase]) |> Stats.summarize()

      IO.puts(
        "#{String.pad_trailing(label, 35)}" <>
          "#{String.pad_leading(Stats.fmt(stats.median), 12)}" <>
          "#{String.pad_leading(Stats.fmt(stats.p95), 12)}" <>
          "#{String.pad_leading(Stats.fmt(stats.min), 12)}" <>
          "#{String.pad_leading(Stats.fmt(stats.max), 12)}"
      )
    end

    _ = runs
  end

  def telemetry_table(table) do
    IO.puts("")

    IO.puts(
      "#{String.pad_trailing("Event", 35)}" <>
        "#{String.pad_leading("median", 12)}" <>
        "#{String.pad_leading("p95", 12)}" <>
        "#{String.pad_leading("count", 10)}"
    )

    IO.puts(String.duplicate("-", 69))

    for event <- [
          [:exgit, :transport, :ls_refs, :stop],
          [:exgit, :transport, :fetch, :stop],
          [:exgit, :pack, :parse, :stop],
          [:exgit, :fs, :walk, :stop],
          [:exgit, :fs, :grep, :stop],
          [:exgit, :object_store, :get, :stop]
        ] do
      durs = Collector.durations(table, event)
      stats = Stats.summarize(durs)

      label =
        event
        |> Enum.drop(1)
        |> Enum.map(&to_string/1)
        |> Enum.join(".")
        |> String.replace(".stop", "")

      IO.puts(
        "#{String.pad_trailing(label, 35)}" <>
          "#{String.pad_leading(Stats.fmt(stats.median), 12)}" <>
          "#{String.pad_leading(Stats.fmt(stats.p95), 12)}" <>
          "#{String.pad_leading(to_string(stats.n), 10)}"
      )
    end
  end
end

defmodule BenchRunner do
  @moduledoc false
  def run_fixture({name, url}, runs) do
    IO.puts("")
    IO.puts("==============================================================")
    IO.puts("Fixture: #{name}  — #{url}")
    IO.puts("==============================================================")

    IO.puts("Warm-up run...")
    _ = Run.one(url, 0)

    events_table = Collector.new()
    Collector.attach(events_table)

    IO.puts("Running #{runs} measured iterations...")

    results =
      for i <- 1..runs do
        r = Run.one(url, i)

        if rem(i, 10) == 0 do
          IO.puts(
            "  #{i}/#{runs}: total=#{Stats.fmt(r.total)} matches=#{r.match_count}"
          )
        end

        r
      end

    Report.header("Phase breakdown (#{name}, #{runs} runs)")
    Report.phase_table(results, runs)

    Report.header("Telemetry event durations (#{name}, across all runs)")
    Report.telemetry_table(events_table)

    match_counts = results |> Enum.map(& &1.match_count) |> Enum.uniq()

    IO.puts(
      "\nMatch-count consistency: #{inspect(match_counts)} (should be a single value)"
    )

    :ok
  end
end

IO.puts("Benchmark: #{runs} runs per fixture")

for fixture <- fixtures do
  BenchRunner.run_fixture(fixture, runs)
end

IO.puts("")
IO.puts("Done.")
