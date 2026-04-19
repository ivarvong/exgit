# Focused benchmark: multi_grep(N patterns) vs N sequential grep(1 pattern)
#
# Multi-signature search — "find any of these N identifiers in the
# repo" — is a common agent workflow (security audits, migrations,
# usage surveys). The naive way is N separate greps, each of which
# walks the whole tree and decompresses every blob. multi_grep
# does one walk, decompresses each blob once, runs N regexes per
# blob.
#
# This benchmark compares wall-clock of both approaches for 3-
# and 10-pattern workloads against real fixtures.
#
# ## Invocation
#
#   mix run bench/multi_grep_bench.exs               # all fixtures, 5 runs
#   mix run bench/multi_grep_bench.exs 10 agents     # 10 runs, agents only

{runs, fixture_filter} =
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
    patterns_3: ["anthropic", "Exgit", "TODO"],
    patterns_10: ["anthropic", "Exgit", "TODO", "def", "import", "from", "class", "async", "await", "return"]
  },
  %{
    name: :agents,
    url: "https://github.com/cloudflare/agents",
    patterns_3: ["agent", "cloudflare", "TODO"],
    patterns_10: ["agent", "cloudflare", "TODO", "export", "import", "function", "const", "async", "await", "return"]
  },
  %{
    name: :claude_sdk,
    url: "https://github.com/anthropics/claude-agent-sdk-python",
    patterns_3: ["claude", "message", "async"],
    patterns_10: ["claude", "message", "async", "def", "import", "from", "class", "return", "self", "await"]
  },
  %{
    name: :opencode,
    url: "https://github.com/anomalyco/opencode",
    patterns_3: ["opencode", "tool", "TODO"],
    patterns_10: ["opencode", "tool", "TODO", "export", "import", "function", "const", "async", "await", "return"]
  }
]

fixtures =
  case fixture_filter do
    :all -> fixtures
    name -> Enum.filter(fixtures, &(&1.name == name))
  end

defmodule MultiGrepBench do
  # Naive: N separate grep calls, then union the result sets.
  def legacy(repo, patterns) do
    for pat <- patterns do
      Exgit.FS.grep(repo, "HEAD", pat) |> Enum.to_list()
    end
    |> List.flatten()
  end

  def new_way(repo, patterns) do
    Exgit.FS.multi_grep(repo, "HEAD", patterns) |> Enum.to_list()
  end
end

defmodule Bench do
  def run(fixture, runs) do
    IO.puts("\n" <> String.duplicate("=", 66))
    IO.puts("Fixture: #{fixture.name}")
    IO.puts("URL: #{fixture.url}")
    IO.puts(String.duplicate("=", 66))

    IO.write("Cloning... ")
    t_clone0 = System.monotonic_time()
    {:ok, repo} = Exgit.clone(fixture.url, lazy: true)
    {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
    t_clone = System.monotonic_time() - t_clone0
    IO.puts(fmt_us(System.convert_time_unit(t_clone, :native, :microsecond)))

    for {label, patterns} <- [{"3 patterns", fixture.patterns_3}, {"10 patterns", fixture.patterns_10}] do
      IO.puts("\n-- #{label} (#{length(patterns)}) --")

      # Warm
      _ = MultiGrepBench.legacy(repo, patterns)
      _ = MultiGrepBench.new_way(repo, patterns)

      # Match-count sanity: multi_grep emits one row per (pattern,
      # match), legacy emits one per match with implicit pattern.
      # Both should have the same overall row count.
      legacy_count = length(MultiGrepBench.legacy(repo, patterns))
      new_count = length(MultiGrepBench.new_way(repo, patterns))
      IO.puts("  match count: legacy=#{legacy_count}  new=#{new_count}")

      legacy_times =
        for _ <- 1..runs do
          {us, _} = :timer.tc(fn -> MultiGrepBench.legacy(repo, patterns) end)
          us
        end

      new_times =
        for _ <- 1..runs do
          {us, _} = :timer.tc(fn -> MultiGrepBench.new_way(repo, patterns) end)
          us
        end

      legacy_med = median(legacy_times)
      new_med = median(new_times)

      IO.puts("  legacy (N× grep):           #{fmt_us(legacy_med)}")
      IO.puts("  new    (multi_grep):        #{fmt_us(new_med)}")

      if new_med > 0 do
        ratio = legacy_med / new_med
        IO.puts("  ratio legacy/new:           #{:io_lib.format("~.2fx", [ratio])}")
      end
    end
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

IO.puts("\nmulti_grep benchmark: one walk + N regexes vs N× full grep")
IO.puts("===========================================================")

for fixture <- fixtures do
  Bench.run(fixture, runs)
end

IO.puts("\nDone.")
