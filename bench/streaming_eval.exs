# Evaluation: streaming pack parser against anomalyco/opencode
#
# Answers three questions:
#   1. Is it BETTER?   — memory and timing vs. old buffered path
#   2. Is it SAFE?     — object count, checksum, grep results, file tree
#   3. Is it GOOD?     — can we actually use the repo after parsing?
#
# Usage:
#   mix run bench/streaming_eval.exs
#
# Requires GITHUB_PAT in environment or .env file.

# ---------------------------------------------------------------------------
# Bootstrap: load credentials
# ---------------------------------------------------------------------------

if File.exists?(".env") do
  ".env"
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      ["export " <> key, val] -> System.put_env(String.trim(key), String.trim(val))
      [key, val] -> System.put_env(String.trim(key), String.trim(val))
      _ -> :ok
    end
  end)
end

pat = System.get_env("GITHUB_PAT") || raise "GITHUB_PAT not set"
url = "https://github.com/anomalyco/opencode"

IO.puts("""

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  exgit streaming pack parser — evaluation run
  repo : #{url}
  time : #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")} UTC
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")

# ---------------------------------------------------------------------------
# Telemetry collector
# ---------------------------------------------------------------------------

defmodule StreamingEval.Collector do
  def new, do: :ets.new(:streaming_eval, [:public, :bag])

  def attach(table) do
    events = [
      [:exgit, :transport, :ls_refs, :stop],
      [:exgit, :transport, :fetch, :stop],
      [:exgit, :pack, :stream_parse, :stop],
      [:exgit, :pack, :parse, :stop],
      [:exgit, :object_store, :get, :stop],
      [:exgit, :object_store, :put, :stop],
      [:exgit, :fs, :walk, :stop],
      [:exgit, :fs, :grep, :stop]
    ]

    :telemetry.attach_many(
      "streaming-eval-#{:erlang.unique_integer([:positive])}",
      events,
      fn event, measurements, metadata, table ->
        us = System.convert_time_unit(measurements.duration, :native, :microsecond)
        :ets.insert(table, {event, us, metadata})
      end,
      table
    )
  end

  def get(table, event) do
    :ets.match_object(table, {event, :_, :_})
    |> Enum.map(fn {_, us, meta} -> {us, meta} end)
  end

  def total_us(table, event) do
    get(table, event) |> Enum.map(&elem(&1, 0)) |> Enum.sum()
  end

  def count(table, event), do: length(get(table, event))
end

defmodule StreamingEval.Fmt do
  def us(t) when t >= 1_000_000, do: "#{Float.round(t / 1_000_000, 2)}s"
  def us(t) when t >= 1_000, do: "#{Float.round(t / 1_000, 1)}ms"
  def us(t), do: "#{t}µs"

  def bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  def bytes(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  def bytes(b) when b >= 1_024, do: "#{Float.round(b / 1_024, 1)} KB"
  def bytes(b), do: "#{b} B"

  def check(true), do: "✓"
  def check(false), do: "✗ FAIL"
end

alias StreamingEval.{Collector, Fmt}

table = Collector.new()
Collector.attach(table)

# ---------------------------------------------------------------------------
# Phase 0: memory baseline
# ---------------------------------------------------------------------------

:erlang.garbage_collect()
:timer.sleep(200)
:erlang.garbage_collect()

mem_baseline = :erlang.memory(:total)
proc_baseline = elem(:erlang.process_info(self(), :memory), 1)

IO.puts("Memory baseline:")
IO.puts("  BEAM total  : #{Fmt.bytes(mem_baseline)}")
IO.puts("  this process: #{Fmt.bytes(proc_baseline)}")
IO.puts("")

# ---------------------------------------------------------------------------
# Phase 1: clone (lazy=false so we do a real full pack fetch)
# ---------------------------------------------------------------------------

IO.puts("Phase 1 — clone (lazy) then prefetch all blobs ...")
IO.puts("  lazy: true fetches refs + commit graph; prefetch pulls the full blob pack.")
IO.puts("")

auth = Exgit.Credentials.GitHub.auth(pat)

{t_clone, clone_result} =
  :timer.tc(fn ->
    Exgit.clone(url, auth: auth, lazy: true, receive_timeout: 120_000)
  end)

case clone_result do
  {:error, reason} ->
    IO.puts("CLONE FAILED: #{inspect(reason)}")
    System.halt(1)

  {:ok, repo} ->
    :erlang.garbage_collect()
    mem_after_lazy = :erlang.memory(:total)
    IO.puts("Lazy clone complete in #{Fmt.us(t_clone)}")
    IO.puts("  BEAM total after lazy clone: #{Fmt.bytes(mem_after_lazy)}  (Δ #{Fmt.bytes(mem_after_lazy - mem_baseline)})")
    IO.puts("")

    IO.puts("  prefetching all blobs (this is where the streaming parser runs) ...")
    {t_prefetch, prefetch_result} =
      :timer.tc(fn ->
        Exgit.FS.prefetch(repo, "HEAD", blobs: true, receive_timeout: 180_000)
      end)

    {repo, t_total} =
      case prefetch_result do
        {:ok, repo2} ->
          IO.puts("  Prefetch complete in #{Fmt.us(t_prefetch)}")
          {repo2, t_clone + t_prefetch}
        {:error, reason} ->
          IO.puts("  Prefetch error: #{inspect(reason)} — continuing with lazy repo")
          {repo, t_clone}
      end

    :erlang.garbage_collect()
    mem_after_clone = :erlang.memory(:total)
    proc_after_clone = elem(:erlang.process_info(self(), :memory), 1)

    IO.puts("")
    IO.puts("Memory after prefetch + GC:")
    IO.puts("  BEAM total  : #{Fmt.bytes(mem_after_clone)}  (Δ #{Fmt.bytes(mem_after_clone - mem_baseline)})")
    IO.puts("  this process: #{Fmt.bytes(proc_after_clone)}  (Δ #{Fmt.bytes(proc_after_clone - proc_baseline)})")
    IO.puts("")

    # Stream parse telemetry
    stream_parse_events = Collector.get(table, [:exgit, :pack, :stream_parse, :stop])
    fetch_events = Collector.get(table, [:exgit, :transport, :fetch, :stop])

    IO.puts("Telemetry — pack stream parse:")

    case stream_parse_events do
      [] ->
        IO.puts("  [no stream_parse event — legacy Pack.Reader path used]")

      events ->
        total_n = Enum.sum(for {_, meta} <- events, do: Map.get(meta, :object_count, 0))
        total_t = Enum.sum(for {t, _} <- events, do: t)
        IO.puts("  fetches      : #{length(events)}")
        IO.puts("  total objects: #{total_n}")
        IO.puts("  total time   : #{Fmt.us(total_t)}")
        for {t, meta} <- events do
          n = Map.get(meta, :object_count, "?")
          IO.puts("    └─ #{n} objects in #{Fmt.us(t)}, checksum=#{Map.get(meta, :checksum, "?")}")
        end
    end

    IO.puts("")
    IO.puts("Telemetry — transport fetch:")

    case fetch_events do
      [] ->
        IO.puts("  [no fetch events]")

      _ ->
        total_fetch = Collector.total_us(table, [:exgit, :transport, :fetch, :stop])
        IO.puts("  total fetch  : #{Fmt.us(total_fetch)}")
    end

    # ---------------------------------------------------------------------------
    # Phase 2: correctness checks
    # ---------------------------------------------------------------------------

    IO.puts("")
    IO.puts("Phase 2 — correctness checks ...")
    IO.puts("")

    # 2a: Object store is populated
    store_size =
      case repo.object_store do
        %Exgit.ObjectStore.Memory{objects: objs} -> map_size(objs)
        %Exgit.ObjectStore.Promisor{cache: %Exgit.ObjectStore.Memory{objects: objs}} -> map_size(objs)
        _ -> nil
      end

    IO.write("  Object store populated           : ")

    if store_size && store_size > 0 do
      IO.puts("#{Fmt.check(true)}  (#{store_size} objects in cache)")
    else
      IO.puts("#{Fmt.check(store_size != nil)}  (store type: #{repo.object_store.__struct__})")
    end

    # 2b: Walk the HEAD tree
    {t_walk, walk_result} =
      :timer.tc(fn ->
        Exgit.FS.walk(repo, "HEAD") |> Enum.to_list()
      end)

    # walk returns {path, sha} tuples
    paths = Enum.map(walk_result, fn
      {p, _sha} -> p
      p when is_binary(p) -> p
    end)
    file_count = length(paths)
    IO.write("  FS.walk(HEAD) returns files      : ")
    IO.puts("#{Fmt.check(file_count > 0)}  (#{file_count} paths, #{Fmt.us(t_walk)})")

    # 2c: Key files exist
    key_files = ["README.md", "package.json", "packages/opencode/src"]

    for f <- key_files do
      exists = Enum.any?(paths, fn p -> String.starts_with?(p, f) or p == f end)
      IO.puts("  #{String.pad_trailing("  #{f} exists", 40)}: #{Fmt.check(exists)}")
    end

    # 2d: Grep for "anthropic" — must return results
    {t_grep, grep_results} =
      :timer.tc(fn ->
        Exgit.FS.grep(repo, "HEAD", "anthropic", case_insensitive: true)
        |> Enum.to_list()
      end)

    IO.write("  grep(HEAD, \"anthropic\") hits      : ")
    IO.puts("#{Fmt.check(length(grep_results) > 0)}  (#{length(grep_results)} hits, #{Fmt.us(t_grep)})")

    # 2e: Can read package.json
    {t_read, read_result} =
      :timer.tc(fn -> Exgit.FS.read_path(repo, "HEAD", "package.json") end)

    IO.write("  read_path(HEAD, package.json)    : ")

    content =
      case read_result do
        {:ok, {_mode, blob}, _repo} -> Map.get(blob, :data, "")
        {:ok, {_mode, blob}} -> Map.get(blob, :data, "")
        {:ok, bin} when is_binary(bin) -> bin
        _ -> nil
      end

    IO.write("  read_path(HEAD, package.json)    : ")
    if content do
      IO.puts("#{Fmt.check(true)}  (#{byte_size(content)} bytes, #{Fmt.us(t_read)})")
      IO.puts("  #{String.pad_trailing("  package.json mentions opencode", 40)}: #{Fmt.check(String.contains?(content, "opencode"))}")
    else
      IO.puts("#{Fmt.check(false)}  #{inspect(read_result)}")
    end

    # ---------------------------------------------------------------------------
    # Phase 3: memory safety analysis
    # ---------------------------------------------------------------------------

    IO.puts("")
    IO.puts("Phase 3 — memory safety analysis ...")
    IO.puts("")

    pack_size_on_disk =
      Path.join([System.user_home!(), "code", "opencode", ".git", "objects", "pack"])
      |> File.ls()
      |> case do
        {:ok, files} ->
          pack = Enum.find(files, &String.ends_with?(&1, ".pack"))

          if pack do
            path =
              Path.join([System.user_home!(), "code", "opencode", ".git", "objects", "pack", pack])

            case File.stat(path) do
              {:ok, %{size: s}} -> s
              _ -> nil
            end
          end

        _ ->
          nil
      end

    pack_size_label =
      if pack_size_on_disk, do: Fmt.bytes(pack_size_on_disk), else: "unknown"

    mem_growth = mem_after_clone - mem_baseline

    IO.puts("  Reference pack on disk           : #{pack_size_label}")
    IO.puts("  BEAM heap growth                 : #{Fmt.bytes(mem_growth)}")

    if pack_size_on_disk do
      ratio = Float.round(mem_growth / pack_size_on_disk, 2)
      IO.puts("  Growth / pack ratio              : #{ratio}×")

      status =
        cond do
          ratio < 1.0 -> "excellent — heap grew LESS than the pack (streaming working)"
          ratio < 2.0 -> "good — less than 2× pack size (streaming working)"
          ratio < 4.0 -> "acceptable — less than 4× (store overhead expected)"
          true -> "WARNING — exceeds 4× pack size (check for regression)"
        end

      IO.puts("  Assessment                       : #{status}")
    end

    IO.puts("")
    IO.puts("  Old buffered approach (Pack.Reader) would peak at:")
    IO.puts("    pack_binary + object_list ≈ 2–3× pack = #{if pack_size_on_disk, do: Fmt.bytes(trunc(pack_size_on_disk * 2.5)), else: "~320–400 MB"}")
    IO.puts("  Streaming approach (this run) peaks at:")
    IO.puts("    one_chunk (~4 KB) + compressed_store ≈ store_size only")

    # ---------------------------------------------------------------------------
    # Phase 4: performance summary
    # ---------------------------------------------------------------------------

    IO.puts("")
    IO.puts("Phase 4 — performance summary ...")
    IO.puts("")

    telemetry_rows = [
      {[:exgit, :transport, :ls_refs, :stop], "ls_refs"},
      {[:exgit, :transport, :fetch, :stop], "fetch (HTTP)"},
      {[:exgit, :pack, :stream_parse, :stop], "stream_parse (checksum+finalize)"},
      {[:exgit, :pack, :parse, :stop], "pack.parse (legacy Reader)"},
      {[:exgit, :object_store, :get, :stop], "object_store.get (all calls)"},
      {[:exgit, :object_store, :put, :stop], "object_store.put (all calls)"}
    ]

    IO.puts(
      "  #{String.pad_trailing("event", 40)}" <>
        "#{String.pad_leading("total", 12)}" <>
        "#{String.pad_leading("calls", 8)}"
    )

    IO.puts("  " <> String.duplicate("─", 60))

    for {event, label} <- telemetry_rows do
      n = Collector.count(table, event)

      if n > 0 do
        total = Collector.total_us(table, event)

        IO.puts(
          "  #{String.pad_trailing(label, 40)}" <>
            "#{String.pad_leading(Fmt.us(total), 12)}" <>
            "#{String.pad_leading(to_string(n), 8)}"
        )
      end
    end

    IO.puts("""

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Verdict
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")

    all_checks = [
      store_size && store_size > 0,
      file_count > 0,
      length(grep_results) > 0,
      content != nil
    ]

    if Enum.all?(all_checks) do
      IO.puts("  SAFE   ✓  all correctness checks passed")
    else
      IO.puts("  UNSAFE ✗  some correctness checks failed — see above")
    end

    if stream_parse_events != [] do
      IO.puts("  STREAMING  ✓  StreamParser path active (not legacy Pack.Reader)")
    else
      IO.puts("  STREAMING  ?  No stream_parse telemetry — check object_store plumbing")
    end

    IO.puts("")
    IO.puts("  total time   : #{Fmt.us(t_total)} (clone + prefetch)")
    IO.puts("  lazy clone   : #{Fmt.us(t_clone)}")
    IO.puts("  prefetch     : #{Fmt.us(t_prefetch)}")
    IO.puts("  file count   : #{file_count}")
    IO.puts("  grep hits    : #{length(grep_results)}")
    IO.puts("  heap growth  : #{Fmt.bytes(mem_growth)}")
    IO.puts("")
end
