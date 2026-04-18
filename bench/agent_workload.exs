# Agent-workload benchmark.
#
# Models a realistic agent session investigating a codebase —
# roughly: an agent trying to answer a user question does ~15-30
# mixed operations (ls, grep, read) in an interactive session
# that stays within one repo. The question this benchmark
# answers is not "how fast is grep?" but "how fast does the
# whole agent interaction complete, and where did the time go?"
#
# This is deliberately different from `review_bench.exs`, which
# measures one-shot `clone + prefetch + grep`. That bench
# optimizes the startup cost. This bench optimizes the
# steady-state cost of an agent DOING work.
#
# ## The workload
#
# A synthetic agent session consists of:
#
#   1. clone (lazy)
#   2. prefetch(blobs: true)
#   3. ls /
#   4. ls one top-level dir
#   5. grep for a literal term       → produces a list of hit paths
#   6. Read 5 grep-hit files
#   7. Read 3 tree-walk files
#   8. grep for a second literal term → accumulates more hit paths
#   9. Read 2 more grep-hit files
#
# Total: 2 greps + ~10 reads + 2 ls calls.
#
# ## Variants
#
#   - `:cold` — fresh clone per run. Measures true end-to-end.
#   - `:hot`  — clone once, run 5 sessions on the same repo.
#     Measures steady-state cache amortization — an agent doing
#     its 2nd, 3rd, 4th task against a repo it already cached.
#
# ## Output
#
# For each fixture × variant, we report:
#   - Session wall-clock (median, p95)
#   - Peak cache_bytes observed during the session
#   - Per-op breakdown from the first session
#
# ## Invocation
#
#   mix run bench/agent_workload.exs                     # all × all, 3 runs
#   mix run bench/agent_workload.exs 5 pyex cold         # 5 runs, pyex, cold
#   mix run bench/agent_workload.exs 3 agents hot        # 3 runs, agents, hot

{runs, fixture_filter, variant_filter} =
  case System.argv() do
    [] -> {3, :all, :all}
    [n] -> {String.to_integer(n), :all, :all}
    [n, f] -> {String.to_integer(n), String.to_atom(f), :all}
    [n, f, v] -> {String.to_integer(n), String.to_atom(f), String.to_atom(v)}
    _ -> {3, :all, :all}
  end

fixtures = [
  %{
    name: :pyex,
    url: "https://github.com/ivarvong/pyex",
    search_term: "anthropic",
    second_search_term: "Exgit"
  },
  %{
    name: :agents,
    url: "https://github.com/cloudflare/agents",
    search_term: "agent",
    second_search_term: "cloudflare"
  },
  %{
    name: :opencode,
    url: "https://github.com/anomalyco/opencode",
    search_term: "opencode",
    second_search_term: "tool"
  }
]

fixtures =
  case fixture_filter do
    :all -> fixtures
    name -> Enum.filter(fixtures, &(&1.name == name))
  end

variants =
  case variant_filter do
    :all -> [:cold, :hot]
    v when v in [:cold, :hot] -> [v]
    _ -> [:cold]
  end

defmodule AgentWorkload do
  @moduledoc """
  Runs one workload session (ls + grep + read mix) against a
  repo. Returns a trace of {op_label, duration_us, cache_bytes}
  tuples for post-run analysis.
  """

  def run_session(repo, ctx) do
    ops = [
      {"ls /", &op_ls_root/2},
      {"ls top_dir", &op_ls_top/2},
      {"grep term1", &op_grep_first/2},
      {"read hit 1", &op_read_grep_hit(&1, &2, 0)},
      {"read hit 2", &op_read_grep_hit(&1, &2, 1)},
      {"read hit 3", &op_read_grep_hit(&1, &2, 2)},
      {"read hit 4", &op_read_grep_hit(&1, &2, 3)},
      {"read hit 5", &op_read_grep_hit(&1, &2, 4)},
      {"read tree 1", &op_read_tree(&1, &2, 0)},
      {"read tree 2", &op_read_tree(&1, &2, 1)},
      {"read tree 3", &op_read_tree(&1, &2, 2)},
      {"grep term2", &op_grep_second/2},
      {"read hit 6", &op_read_grep_hit(&1, &2, 5)},
      {"read hit 7", &op_read_grep_hit(&1, &2, 6)}
    ]

    {trace, final_repo, _final_ctx} =
      Enum.reduce(ops, {[], repo, ctx}, fn {label, op}, {tr, r, c} ->
        {duration, {new_r, new_c}} = :timer.tc(fn -> op.(r, c) end)
        cb = cache_bytes(new_r)
        {[{label, duration, cb} | tr], new_r, new_c}
      end)

    {Enum.reverse(trace), final_repo}
  end

  defp op_ls_root(repo, ctx) do
    case Exgit.FS.ls(repo, "HEAD", "") do
      {:ok, _entries, new_repo} -> {new_repo, ctx}
      _ -> {repo, ctx}
    end
  end

  defp op_ls_top(repo, ctx) do
    case Exgit.FS.ls(repo, "HEAD", "") do
      {:ok, entries, new_repo} ->
        dir =
          entries
          |> Enum.filter(fn {mode, _, _} -> mode == "40000" end)
          |> Enum.map(fn {_, name, _} -> name end)
          |> Enum.reject(&(&1 in [".github", ".git", "node_modules", "_build", "deps"]))
          |> List.first()

        case dir do
          nil ->
            {new_repo, ctx}

          d ->
            case Exgit.FS.ls(new_repo, "HEAD", d) do
              {:ok, _, r} -> {r, ctx}
              _ -> {new_repo, ctx}
            end
        end

      _ ->
        {repo, ctx}
    end
  end

  defp op_grep_first(repo, ctx) do
    hits = Exgit.FS.grep(repo, "HEAD", ctx.search_term, case_insensitive: true) |> Enum.to_list()
    paths = hits |> Enum.map(& &1.path) |> Enum.uniq()
    {repo, %{ctx | grep_paths: paths}}
  end

  defp op_grep_second(repo, ctx) do
    hits =
      Exgit.FS.grep(repo, "HEAD", ctx.second_search_term, case_insensitive: true)
      |> Enum.to_list()

    paths = hits |> Enum.map(& &1.path) |> Enum.uniq()
    {repo, %{ctx | grep_paths: ctx.grep_paths ++ paths}}
  end

  defp op_read_grep_hit(repo, ctx, idx) do
    read_at(repo, ctx, :grep_paths, idx)
  end

  defp op_read_tree(repo, ctx, idx) do
    read_at(repo, ctx, :tree_paths, idx)
  end

  defp read_at(repo, ctx, key, idx) do
    path = ctx |> Map.get(key) |> Enum.at(idx)

    if is_binary(path) do
      case Exgit.FS.read_path(repo, "HEAD", path) do
        {:ok, _, new_repo} -> {new_repo, ctx}
        _ -> {repo, ctx}
      end
    else
      {repo, ctx}
    end
  end

  defp cache_bytes(%Exgit.Repository{
         object_store: %Exgit.ObjectStore.Promisor{cache_bytes: b}
       }),
       do: b

  defp cache_bytes(_), do: 0
end

defmodule Runner do
  @moduledoc false

  def run(fixture, variant, runs) do
    IO.puts("\n" <> String.duplicate("=", 66))
    IO.puts("Fixture: #{fixture.name}  /  Variant: #{variant}  /  Runs: #{runs}")
    IO.puts("URL: #{fixture.url}")
    IO.puts(String.duplicate("=", 66))

    IO.puts("Warming up...")
    _ = measure_session(fixture, variant)

    sessions =
      for i <- 1..runs do
        IO.write("Run #{i}/#{runs}... ")
        session = measure_session(fixture, variant)

        IO.puts(
          "#{fmt_us(session.total_us)} (peak cache #{fmt_bytes(session.peak_cache_bytes)})"
        )

        session
      end

    report(sessions, fixture, variant)
  end

  defp measure_session(fixture, variant) do
    t0 = System.monotonic_time()

    {_t_clone, {:ok, repo}} = :timer.tc(fn -> Exgit.clone(fixture.url, lazy: true) end)

    {_t_prefetch, {:ok, repo}} =
      :timer.tc(fn -> Exgit.FS.prefetch(repo, "HEAD", blobs: true) end)

    # Pre-materialize ~20 tree paths so read_tree has material to
    # work with regardless of grep result count.
    tree_paths =
      Exgit.FS.walk(repo, "HEAD")
      |> Enum.take(20)
      |> Enum.map(&elem(&1, 0))

    ctx = %{
      search_term: fixture.search_term,
      second_search_term: fixture.second_search_term,
      grep_paths: [],
      tree_paths: tree_paths
    }

    {all_traces, _final_repo} =
      case variant do
        :hot ->
          # Clone once, run 5 sessions. Reports on the 5th
          # session (steady state) implicitly via the combined
          # trace — the first session pays cold-cache costs, the
          # next 4 are warm.
          Enum.reduce(1..5, {[], repo}, fn _i, {traces, r} ->
            {trace, new_r} = AgentWorkload.run_session(r, ctx)
            {traces ++ [trace], new_r}
          end)

        :cold ->
          {trace, new_repo} = AgentWorkload.run_session(repo, ctx)
          {[trace], new_repo}
      end

    total_us =
      System.monotonic_time()
      |> Kernel.-(t0)
      |> System.convert_time_unit(:native, :microsecond)

    flat = List.flatten(all_traces)
    peak = flat |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> 0 end)

    %{total_us: total_us, sessions: all_traces, peak_cache_bytes: peak}
  end

  defp report(sessions, _fixture, variant) do
    n = length(sessions)
    sorted_total = sessions |> Enum.map(& &1.total_us) |> Enum.sort()
    median = Enum.at(sorted_total, div(n, 2))
    p95 = Enum.at(sorted_total, min(n - 1, trunc(n * 0.95)))
    peaks = sessions |> Enum.map(& &1.peak_cache_bytes)

    IO.puts("\nSession totals (N=#{n})")
    IO.puts("  median: #{fmt_us(median)}")
    IO.puts("  p95:    #{fmt_us(p95)}")
    IO.puts("  peak cache median/max: #{fmt_bytes(median_of(peaks))} / #{fmt_bytes(Enum.max(peaks))}")

    IO.puts("\nPer-op median (first session of first run, variant #{variant}):")
    first_session = hd(hd(sessions).sessions)

    for {label, duration_us, cache_bytes} <- first_session do
      IO.puts(
        "  #{String.pad_trailing(label, 14)} #{fmt_us(duration_us) |> String.pad_leading(10)}   (cache: #{fmt_bytes(cache_bytes)})"
      )
    end
  end

  defp median_of(nums) do
    sorted = Enum.sort(nums)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp fmt_us(us) when us >= 1_000_000,
    do: :io_lib.format("~.2f s", [us / 1_000_000]) |> to_string()

  defp fmt_us(us) when us >= 1_000, do: :io_lib.format("~.1f ms", [us / 1_000]) |> to_string()
  defp fmt_us(us), do: "#{us} µs"

  defp fmt_bytes(b) when b >= 1_048_576,
    do: :io_lib.format("~.1f MB", [b / 1_048_576]) |> to_string()

  defp fmt_bytes(b) when b >= 1024, do: :io_lib.format("~.1f KB", [b / 1024]) |> to_string()
  defp fmt_bytes(b), do: "#{b} B"
end

IO.puts("\nAgent-workload benchmark")
IO.puts("========================")

for fixture <- fixtures, variant <- variants do
  Runner.run(fixture, variant, runs)
end

IO.puts("\nDone.")
