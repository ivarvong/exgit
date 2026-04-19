# Blame benchmark: real-fixture per-file blame wall-clock.
#
# Blame is fundamentally commit-history-dependent: cost scales
# with (lines × commits_touching_file). A 300-line file with 5
# commits is fast; a 1500-line file with 100 commits is not.
# This benchmark measures the actual latency an agent would see
# for a handful of representative files across fixtures.
#
# ## Invocation
#
#   mix run bench/blame_bench.exs               # all fixtures, 3 runs
#   mix run bench/blame_bench.exs 5 claude_sdk  # 5 runs, claude_sdk only

{runs, fixture_filter} =
  case System.argv() do
    [] -> {3, :all}
    [n] -> {String.to_integer(n), :all}
    [n, f] -> {String.to_integer(n), String.to_atom(f)}
    _ -> {3, :all}
  end

fixtures = [
  %{
    name: :pyex,
    url: "https://github.com/ivarvong/pyex",
    paths: ["README.md", "pyex/client.py"]
  },
  %{
    name: :claude_sdk,
    url: "https://github.com/anthropics/claude-agent-sdk-python",
    paths: [
      "README.md",
      "CHANGELOG.md",
      "src/claude_agent_sdk/_cli_version.py",
      "pyproject.toml"
    ]
  }
]

fixtures =
  case fixture_filter do
    :all -> fixtures
    name -> Enum.filter(fixtures, &(&1.name == name))
  end

defmodule BlameBench do
  def run(fixture, runs) do
    IO.puts("\n" <> String.duplicate("=", 66))
    IO.puts("Fixture: #{fixture.name}")
    IO.puts("URL: #{fixture.url}")
    IO.puts(String.duplicate("=", 66))

    IO.write("Cloning... ")
    t0 = System.monotonic_time()
    {:ok, repo} = Exgit.clone(fixture.url, lazy: true)
    {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
    IO.puts(fmt_us(System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)))

    IO.puts("\n#{String.pad_trailing("path", 50)}#{String.pad_leading("lines", 10)}#{String.pad_leading("median", 12)}")

    for path <- fixture.paths do
      # Warm
      case Exgit.Blame.blame(repo, "HEAD", path) do
        {:ok, _, _} -> :ok
        err -> IO.inspect({path, err}, label: "skip")
      end

      times =
        for _ <- 1..runs do
          {us, result} = :timer.tc(fn -> Exgit.Blame.blame(repo, "HEAD", path) end)

          case result do
            {:ok, entries, _} -> {us, length(entries)}
            _ -> {us, -1}
          end
        end

      {lines, med_us} = summarize(times)

      IO.puts(
        "#{String.pad_trailing(path, 50)}#{String.pad_leading("#{lines}", 10)}#{String.pad_leading(fmt_us(med_us), 12)}"
      )
    end
  end

  defp summarize(times) do
    sorted = Enum.sort_by(times, &elem(&1, 0))
    {med_us, lines} = Enum.at(sorted, div(length(sorted), 2))
    {lines, med_us}
  end

  defp fmt_us(us) when us >= 1_000_000,
    do: :io_lib.format("~.2f s", [us / 1_000_000]) |> to_string()

  defp fmt_us(us) when us >= 1_000, do: :io_lib.format("~.1f ms", [us / 1_000]) |> to_string()
  defp fmt_us(us), do: "#{us} µs"
end

IO.puts("\nBlame benchmark")
IO.puts("===============")

for fixture <- fixtures do
  BlameBench.run(fixture, runs)
end

IO.puts("\nDone.")
