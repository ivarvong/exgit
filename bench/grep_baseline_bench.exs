# grep baseline benchmark.
#
# The focused question: "If I grep a simple literal string in my
# repo, how long does it take, and where is the time going?"
#
# This is deliberately narrower than agent_session_bench or
# agent_workload — one primitive, four phases timed cleanly.
# Used to establish the baseline before any further grep
# optimization work (cancellation, chunked parallelism,
# decompressed-blob cache, etc.) and to surface the honest
# cold-vs-warm split.
#
# ## Phases
#
#   1. clone     — Exgit.clone(url, lazy: true)
#   2. prefetch  — Exgit.FS.prefetch(repo, "HEAD", blobs: true)
#   3. grep_cold — first Exgit.FS.grep call. Pays the cost of
#                  any on-demand fetches triggered by the walk
#                  (first time a commit / tree sha is hit) that
#                  prefetch didn't absorb.
#   4. grep_warm — median of N subsequent Exgit.FS.grep calls.
#                  Everything is in-memory at this point;
#                  represents steady-state agent / LV latency.
#
# ## Invocation
#
#   mix run bench/grep_baseline_bench.exs               # all fixtures, N=5 warm runs
#   mix run bench/grep_baseline_bench.exs 10 claude_sdk # 10 warm runs, claude_sdk
#
# Networks vary. Numbers below measured on a home residential
# connection should be read as "my baseline," not "the
# baseline."

{warm_runs, fixture_filter} =
  case System.argv() do
    [] -> {5, :all}
    [n] -> {String.to_integer(n), :all}
    [n, f] -> {String.to_integer(n), String.to_atom(f)}
    _ -> {5, :all}
  end

fixtures = [
  %{
    name: :pyex,
    url: "https://github.com/ivarvong/pyex",
    # Literal string guaranteed to match in this repo.
    query: "anthropic"
  },
  %{
    name: :claude_sdk,
    url: "https://github.com/anthropics/claude-agent-sdk-python",
    query: "claude"
  },
  %{
    name: :agents,
    url: "https://github.com/cloudflare/agents",
    query: "agent"
  },
  %{
    name: :opencode,
    url: "https://github.com/anomalyco/opencode",
    query: "opencode"
  }
]

fixtures =
  case fixture_filter do
    :all -> fixtures
    name -> Enum.filter(fixtures, &(&1.name == name))
  end

defmodule GrepBaseline do
  def measure(fixture, warm_runs) do
    IO.puts("\n" <> String.duplicate("=", 74))
    IO.puts("Fixture: #{fixture.name}  /  query: #{inspect(fixture.query)}")
    IO.puts("URL: #{fixture.url}")
    IO.puts(String.duplicate("=", 74))

    # --- Phase 1: clone ---
    {clone_us, {:ok, repo}} =
      :timer.tc(fn -> Exgit.clone(fixture.url, lazy: true) end)

    # --- Phase 2: prefetch ---
    {prefetch_us, {:ok, repo}} =
      :timer.tc(fn -> Exgit.FS.prefetch(repo, "HEAD", blobs: true) end)

    # --- Phase 3: first grep (cold — no warmup) ---
    {cold_us, cold_results} =
      :timer.tc(fn ->
        Exgit.FS.grep(repo, "HEAD", fixture.query) |> Enum.to_list()
      end)

    # --- Phase 4: warm greps ---
    warm_times =
      for _ <- 1..warm_runs do
        {us, _} =
          :timer.tc(fn ->
            Exgit.FS.grep(repo, "HEAD", fixture.query) |> Enum.to_list()
          end)

        us
      end

    warm_med = median(warm_times)

    # --- Also measure total files walked so per-file cost is visible ---
    file_count = Exgit.FS.walk(repo, "HEAD") |> Enum.count()

    hit_count = length(cold_results)

    # --- Report ---
    IO.puts("\nWorkload shape:")
    IO.puts("  files walked: #{file_count}")
    IO.puts("  grep hits:    #{hit_count}")

    IO.puts("\nPer-phase timing:")
    report_row("clone (lazy)", clone_us)
    report_row("prefetch (HEAD + blobs)", prefetch_us)
    report_row("grep COLD (first call)", cold_us)

    IO.puts("  " <> String.pad_trailing("grep WARM (median of #{warm_runs})", 32) <> fmt_us(warm_med))

    if warm_med > 0 do
      per_file = warm_med / max(file_count, 1)
      IO.puts("    per-file (warm): #{:io_lib.format("~.1f", [per_file])} µs/file")
    end

    # First-match latency: how long before the stream produces
    # one result? This matters most for LV — "time to first
    # paint." Measured on a fresh invocation (warm cache), taking
    # Stream.take(1).
    {ttfm_us, _} =
      :timer.tc(fn ->
        Exgit.FS.grep(repo, "HEAD", fixture.query) |> Enum.take(1)
      end)

    IO.puts("  " <> String.pad_trailing("time-to-first-match (warm)", 32) <> fmt_us(ttfm_us))

    IO.puts("\nDelta cold → warm: #{:io_lib.format("~.2fx", [cold_us / max(warm_med, 1)])}")

    IO.puts("\nRaw warm timings (µs): #{inspect(warm_times)}")

    %{
      fixture: fixture.name,
      clone_us: clone_us,
      prefetch_us: prefetch_us,
      grep_cold_us: cold_us,
      grep_warm_med_us: warm_med,
      ttfm_us: ttfm_us,
      file_count: file_count,
      hit_count: hit_count
    }
  end

  defp report_row(label, us) do
    IO.puts("  " <> String.pad_trailing(label, 32) <> fmt_us(us))
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

defmodule Summary do
  def print(results) do
    IO.puts("\n" <> String.duplicate("=", 74))
    IO.puts("SUMMARY (across all fixtures)")
    IO.puts(String.duplicate("=", 74))

    header = "fixture    files  hits    clone    prefetch     cold      warm    ttfm"
    IO.puts("\n#{header}")
    IO.puts(String.duplicate("-", 74))

    for r <- results do
      IO.puts(
        [
          String.pad_trailing(Atom.to_string(r.fixture), 10),
          String.pad_leading("#{r.file_count}", 6),
          String.pad_leading("#{r.hit_count}", 6),
          String.pad_leading(fmt(r.clone_us), 10),
          String.pad_leading(fmt(r.prefetch_us), 10),
          String.pad_leading(fmt(r.grep_cold_us), 10),
          String.pad_leading(fmt(r.grep_warm_med_us), 10),
          String.pad_leading(fmt(r.ttfm_us), 10)
        ]
        |> Enum.join("")
      )
    end

    IO.puts("")
  end

  defp fmt(us) when us >= 1_000_000,
    do: :io_lib.format("~.1fs", [us / 1_000_000]) |> to_string()

  defp fmt(us) when us >= 1_000, do: "#{round(us / 1_000)}ms"
  defp fmt(us), do: "#{us}µs"
end

IO.puts("\ngrep baseline benchmark")
IO.puts("=======================")

results =
  for fixture <- fixtures do
    GrepBaseline.measure(fixture, warm_runs)
  end

Summary.print(results)

IO.puts("Done.")
