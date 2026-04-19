# Focused benchmark: "grep then read context of each hit"
#
# This is the exact agent workflow the Round 1 features were
# designed for. Compares two ways to produce the same result:
#
#   OLD: grep → for each hit, read_path → slice surrounding lines
#   NEW: grep with :context → results already include surrounding lines
#
# Reports wall-clock per approach, per fixture, and the
# end-to-end ratio. No other agent overhead, no session loop —
# just the grep+read combo so the measurement isolates what
# changed.
#
# ## Invocation
#
#   mix run bench/grep_context_bench.exs               # all fixtures, 5 runs
#   mix run bench/grep_context_bench.exs 10 pyex       # 10 runs, pyex only

{runs, fixture_filter} =
  case System.argv() do
    [] -> {5, :all}
    [n] -> {String.to_integer(n), :all}
    [n, f] -> {String.to_integer(n), String.to_atom(f)}
    _ -> {5, :all}
  end

fixtures = [
  %{name: :pyex, url: "https://github.com/ivarvong/pyex", term: "anthropic"},
  %{name: :agents, url: "https://github.com/cloudflare/agents", term: "agent"},
  %{name: :claude_sdk, url: "https://github.com/anthropics/claude-agent-sdk-python", term: "claude"},
  %{name: :opencode, url: "https://github.com/anomalyco/opencode", term: "opencode"}
]

fixtures =
  case fixture_filter do
    :all -> fixtures
    name -> Enum.filter(fixtures, &(&1.name == name))
  end

defmodule GrepCtxBench do
  @context 3
  @max_hits 20

  # Legacy approach: grep then read_path each hit, slice context
  # manually.
  def legacy(repo, term) do
    hits =
      repo
      |> Exgit.FS.grep("HEAD", term, case_insensitive: true)
      |> Enum.take(@max_hits)

    for hit <- hits do
      case Exgit.FS.read_path(repo, "HEAD", hit.path) do
        {:ok, {_mode, blob}, _repo} ->
          lines = String.split(blob.data, "\n")
          line_idx = hit.line_number - 1

          before_from = max(0, line_idx - @context)
          before_to = line_idx - 1

          before_lines =
            if before_to >= before_from,
              do: Enum.slice(lines, before_from..before_to//1),
              else: []

          after_from = line_idx + 1
          after_to = min(length(lines) - 1, line_idx + @context)

          after_lines =
            if after_to >= after_from,
              do: Enum.slice(lines, after_from..after_to//1),
              else: []

          %{
            path: hit.path,
            line_number: hit.line_number,
            line: hit.line,
            match: hit.match,
            context_before: Enum.with_index(before_lines, max(1, hit.line_number - @context)),
            context_after: Enum.with_index(after_lines, hit.line_number + 1)
          }

        _ ->
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  # New approach: grep with context.
  def new_way(repo, term) do
    repo
    |> Exgit.FS.grep("HEAD", term, case_insensitive: true, context: @context)
    |> Enum.take(@max_hits)
  end
end

defmodule Bench do
  def run(fixture, runs) do
    IO.puts("\n" <> String.duplicate("=", 66))
    IO.puts("Fixture: #{fixture.name}  /  Term: #{inspect(fixture.term)}")
    IO.puts("URL: #{fixture.url}")
    IO.puts(String.duplicate("=", 66))

    IO.write("Cloning... ")
    t_clone0 = System.monotonic_time()
    {:ok, repo} = Exgit.clone(fixture.url, lazy: true)
    {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
    t_clone = System.monotonic_time() - t_clone0
    IO.puts(fmt_us(System.convert_time_unit(t_clone, :native, :microsecond)))

    # Warm-up
    _ = GrepCtxBench.legacy(repo, fixture.term)
    _ = GrepCtxBench.new_way(repo, fixture.term)

    # Invariant check: both produce equivalent result count.
    legacy_count = length(GrepCtxBench.legacy(repo, fixture.term))
    new_count = length(GrepCtxBench.new_way(repo, fixture.term))

    IO.puts("Hit count: legacy=#{legacy_count}  new=#{new_count}")

    legacy_times =
      for _ <- 1..runs do
        {us, _} = :timer.tc(fn -> GrepCtxBench.legacy(repo, fixture.term) end)
        us
      end

    new_times =
      for _ <- 1..runs do
        {us, _} = :timer.tc(fn -> GrepCtxBench.new_way(repo, fixture.term) end)
        us
      end

    legacy_med = median(legacy_times)
    new_med = median(new_times)

    IO.puts("\nResult (median over #{runs} runs):")
    IO.puts("  legacy (grep + N×read_path):   #{fmt_us(legacy_med)}")
    IO.puts("  new    (grep with :context):   #{fmt_us(new_med)}")

    if new_med > 0 do
      ratio = legacy_med / new_med
      IO.puts("  ratio legacy/new:              #{:io_lib.format("~.2fx", [ratio])}")
    end

    IO.puts("\nRaw timings (µs):")
    IO.puts("  legacy: #{inspect(legacy_times)}")
    IO.puts("  new:    #{inspect(new_times)}")
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

IO.puts("\ngrep+context benchmark: old way vs new :context option")
IO.puts("=======================================================")

for fixture <- fixtures do
  Bench.run(fixture, runs)
end

IO.puts("\nDone.")
