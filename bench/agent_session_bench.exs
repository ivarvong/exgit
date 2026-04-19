# End-to-end agent-session benchmark.
#
# Simulates the full shape of an agent investigating a codebase.
# Unlike agent_workload.exs (which is primarily ls + grep + read
# in a loop), this exercises the Round 1 + Round 2 primitives
# (grep with context, read_lines, multi_grep, blame) in the
# configurations an agent actually uses.
#
# ## The workflow
#
#   1. clone (lazy) + prefetch
#   2. multi_grep 3 patterns (security-audit style)
#   3. For each of 5 hits: grep with context:3 on the file
#      (this is the "show me the match with surrounding code"
#      pattern)
#   4. For 2 hits: blame the file (who introduced this?)
#   5. For 1 hit: read_lines wider context (N+/-10 lines)
#
# Each primitive reports its own timing; the final number is
# total wall-clock. What we care about: is this latency
# acceptable for an interactive agent step?
#
# ## Invocation
#
#   mix run bench/agent_session_bench.exs               # all fixtures, 3 runs
#   mix run bench/agent_session_bench.exs 5 claude_sdk  # 5 runs, claude_sdk

{runs, fixture_filter} =
  case System.argv() do
    [] -> {3, :all}
    [n] -> {String.to_integer(n), :all}
    [n, f] -> {String.to_integer(n), String.to_atom(f)}
    _ -> {3, :all}
  end

fixtures = [
  %{
    name: :claude_sdk,
    url: "https://github.com/anthropics/claude-agent-sdk-python",
    patterns: %{
      auth: ~r/token|auth/i,
      secret: ~r/secret|api_key/i,
      todo: "TODO"
    }
  },
  %{
    name: :agents,
    url: "https://github.com/cloudflare/agents",
    patterns: %{
      auth: ~r/token|auth/i,
      secret: ~r/secret|api_key/i,
      todo: "TODO"
    }
  }
]

fixtures =
  case fixture_filter do
    :all -> fixtures
    name -> Enum.filter(fixtures, &(&1.name == name))
  end

defmodule AgentSession do
  def run_session(repo, patterns) do
    timings = %{}

    # Step 1: multi_grep (first investigation pass).
    {step1_us, hits} =
      :timer.tc(fn ->
        Exgit.FS.multi_grep(repo, "HEAD", patterns, max_count: 50)
        |> Enum.to_list()
      end)

    timings = Map.put(timings, :multi_grep, step1_us)

    # Pick 5 hits for context reads (favoring unique paths).
    context_hits =
      hits
      |> Enum.uniq_by(& &1.path)
      |> Enum.take(5)

    # Step 2: For each of up to 5 hits, grep with context on the file
    # to simulate "show me the match with surrounding code." An agent
    # typically does this per-file, not per-match.
    {step2_us, _context_results} =
      :timer.tc(fn ->
        for hit <- context_hits do
          # Grep just this file with context.
          Exgit.FS.grep(repo, "HEAD", hit.match,
            path: hit.path,
            context: 3,
            max_count: 1
          )
          |> Enum.to_list()
        end
      end)

    timings = Map.put(timings, :grep_with_context, step2_us)

    # Step 3: Blame the top 2 hit files (attribution check).
    # Safeguard: blame cost scales with history; cap at 2 files
    # which keeps the step budget reasonable.
    blame_paths =
      context_hits
      |> Enum.take(2)
      |> Enum.map(& &1.path)

    {step3_us, _blame_results} =
      :timer.tc(fn ->
        for path <- blame_paths do
          Exgit.Blame.blame(repo, "HEAD", path)
        end
      end)

    timings = Map.put(timings, :blame, step3_us)

    # Step 4: read_lines for 1 hit (wider context window).
    read_lines_us =
      case List.first(context_hits) do
        nil ->
          0

        hit ->
          {us, _} =
            :timer.tc(fn ->
              start = max(1, hit.line_number - 10)
              fin = hit.line_number + 10
              Exgit.FS.read_lines(repo, "HEAD", hit.path, start..fin)
            end)

          us
      end

    timings = Map.put(timings, :read_lines, read_lines_us)

    total_us = Map.values(timings) |> Enum.sum()

    %{
      total_us: total_us,
      timings: timings,
      hit_count: length(hits),
      context_files: length(context_hits),
      blame_files: length(blame_paths)
    }
  end
end

defmodule Bench do
  def run(fixture, runs) do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("Fixture: #{fixture.name}")
    IO.puts("URL: #{fixture.url}")
    IO.puts(String.duplicate("=", 70))

    IO.write("Cloning + prefetching... ")
    t0 = System.monotonic_time()
    {:ok, repo} = Exgit.clone(fixture.url, lazy: true)
    {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
    clone_us = System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)
    IO.puts(fmt_us(clone_us))

    # Warm
    _ = AgentSession.run_session(repo, fixture.patterns)

    # Actual timed runs
    results =
      for i <- 1..runs do
        result = AgentSession.run_session(repo, fixture.patterns)
        IO.puts("  run #{i}: #{fmt_us(result.total_us)} (hits=#{result.hit_count})")
        result
      end

    # Summarize
    IO.puts("\nSession latency (N=#{runs}, median):")
    med_total = median(Enum.map(results, & &1.total_us))
    IO.puts("  total:         #{fmt_us(med_total)}")

    steps = [:multi_grep, :grep_with_context, :blame, :read_lines]

    for step <- steps do
      step_times = Enum.map(results, &Map.get(&1.timings, step))
      IO.puts("  #{String.pad_trailing(Atom.to_string(step), 16)} #{fmt_us(median(step_times))}")
    end

    first = List.first(results)
    IO.puts("\nWorkload shape:")
    IO.puts("  multi_grep hits: #{first.hit_count}")
    IO.puts("  context files:   #{first.context_files}")
    IO.puts("  blame files:     #{first.blame_files}")
  end

  defp median(nums) do
    sorted = Enum.sort(nums)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp fmt_us(us) when us >= 1_000_000,
    do: :io_lib.format("~.2f s", [us / 1_000_000]) |> to_string()

  defp fmt_us(us) when us >= 1_000, do: :io_lib.format("~.1f ms", [us / 1_000]) |> to_string()
  defp fmt_us(us), do: "#{us} µs"
end

IO.puts("\nEnd-to-end agent session benchmark")
IO.puts("==================================")

for fixture <- fixtures do
  Bench.run(fixture, runs)
end

IO.puts("\nDone.")
