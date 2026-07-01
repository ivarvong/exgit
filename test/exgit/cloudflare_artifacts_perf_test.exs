defmodule Exgit.CloudflareArtifactsPerfTest do
  @moduledoc """
  Performance benchmark for Cloudflare Artifacts: bootstrap clone time
  and per-blob first-touch latency across exgit's three clone modes.

  Modes:

    * `eager`            — full clone, all objects fetched up front
    * `filter:{:blob, :none}` — refs + commits + trees, blobs on demand
    * `lazy: true`        — refs only, commits + trees + blobs on demand

  Seeds a fresh repo with `@file_count × @file_bytes` random blobs in a
  single commit, then runs `@clone_iterations` clones × `@reads_per_clone`
  first-touch reads per partial mode. Reports compressed pack bytes
  per clone and p50/p95/p99 latency for clone time and per-read time.

  Begins with a capability sniff: a single `filter:{:blob, :none}`
  clone. Exgit returns `{:error, {:filter_unsupported, _}}` if the
  server doesn't advertise the protocol-v2 `filter` capability — that
  itself is the headline finding for partial-clone support.

  Tagged `:cloudflare_perf`. Run with `mix test --include cloudflare_perf`.
  Requires `CF_ACCOUNT_ID` and `CF_API_TOKEN`; auto-skipped via
  `test_helper.exs` when those aren't set.
  """

  use ExUnit.Case, async: false

  @moduletag :cloudflare_perf
  @moduletag timeout: 1_800_000

  alias Exgit.CloudflareArtifacts
  alias Exgit.CloudflareArtifacts.{Repo, Token}
  alias Exgit.Credentials.Artifacts, as: ArtifactsCreds
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore
  alias Exgit.ObjectStore.Promisor
  alias Exgit.{RefStore, Repository, Transport}
  alias Exgit.Test.CloudflareArtifacts, as: CFEnv

  @file_count 1_000
  @file_bytes 1_024
  @clone_iterations 10
  @reads_per_clone 50

  setup_all do
    client =
      CloudflareArtifacts.new(
        account_id: CFEnv.account_id(),
        namespace: CFEnv.namespace(),
        api_token: CFEnv.api_token()
      )

    repo_name = "exgit-perf-#{System.system_time(:millisecond)}-#{rand_hex(4)}"

    on_exit(fn -> _ = CloudflareArtifacts.delete_repo(client, repo_name) end)

    {:ok, %Repo{remote: remote}} =
      CloudflareArtifacts.create_repo(client,
        name: repo_name,
        default_branch: "main",
        description: "exgit perf benchmark"
      )

    {:ok, %Token{plaintext: write_token}} =
      CloudflareArtifacts.create_token(client,
        repo: repo_name,
        scope: "write",
        ttl: 7200
      )

    {:ok, %Token{plaintext: read_token}} =
      CloudflareArtifacts.create_token(client,
        repo: repo_name,
        scope: "read",
        ttl: 7200
      )

    branch = "refs/heads/main"

    IO.puts("\n[perf] building seed: #{@file_count} × #{@file_bytes}B random blobs ...")

    {build_us, {seed_repo, _commit_sha, filenames}} =
      :timer.tc(fn -> build_seed_commit(branch, @file_count, @file_bytes) end)

    IO.puts("[perf] seed built locally in #{us_to_ms(build_us)} ms")

    write_transport = Transport.HTTP.new(remote, auth: ArtifactsCreds.auth(write_token))

    IO.puts("[perf] pushing seed to CF ...")

    {push_us, {:ok, %{ref_results: ref_results}}} =
      :timer.tc(fn -> Exgit.push(seed_repo, write_transport, refspecs: [branch]) end)

    assert Enum.any?(ref_results, &match?({^branch, :ok}, &1))
    IO.puts("[perf] pushed in #{us_to_ms(push_us)} ms")

    {:ok,
     %{
       branch: branch,
       filenames: filenames,
       remote: remote,
       read_token: read_token
     }}
  end

  test "perf: clone modes against CF Artifacts", ctx do
    IO.puts("\n========== CF Artifacts Clone-Mode Benchmark ==========")

    IO.puts(
      "repo size: #{@file_count} files × #{@file_bytes} bytes = " <>
        "#{@file_count * @file_bytes} bytes raw"
    )

    IO.puts("clones per mode: #{@clone_iterations}")
    IO.puts("first-touch reads per partial-mode clone: #{@reads_per_clone}")

    IO.puts("\n--- Capability check ---")
    {filter_supported?, sniff_msg} = check_filter_capability(ctx)
    IO.puts(sniff_msg)

    if not filter_supported? do
      IO.puts(check_lazy_capability(ctx))
    end

    eager_stats = bench_eager(ctx, @clone_iterations)

    filter_stats =
      if filter_supported? do
        bench_partial(ctx, :filter_blob_none, @clone_iterations, @reads_per_clone)
      else
        IO.puts("\n[perf] skipping filter:{:blob, :none} benchmark (capability not advertised).")
        nil
      end

    # Run lazy regardless: even when the server doesn't advertise
    # `filter`, exgit's on-demand fetch path still sends `filter:
    # blob:none` per fetch — the server may silently ignore it (and
    # ship the full pack each time, which would make lazy strictly
    # worse than eager) or honor it (in which case lazy works and
    # the capability advertisement is just a docs lie).
    lazy_stats = bench_partial(ctx, :lazy, @clone_iterations, @reads_per_clone)

    print_summary(eager_stats, filter_stats, lazy_stats)
  end

  # --- Capability sniff ---

  defp check_filter_capability(ctx) do
    transport = make_transport(ctx)

    case Exgit.clone(transport, filter: {:blob, :none}) do
      {:ok, %Repository{object_store: %Promisor{cache_bytes: bytes} = store}} ->
        n = count_cached_objects(store)

        msg =
          "[perf] CF advertises `filter` capability — partial clone succeeded.\n" <>
            "[perf]   bootstrap fetched #{n} objects, #{bytes} compressed bytes\n" <>
            "[perf]   (eager would fetch #{@file_count + 2} objects: #{@file_count} blobs + 1 tree + 1 commit)"

        {true, msg}

      {:error, {:filter_unsupported, _} = err} ->
        msg =
          "[perf] CF does NOT advertise `filter` capability.\n" <>
            "[perf]   exgit error: #{inspect(err)}\n" <>
            "[perf]   Implication: partial-clone agent workloads pay the full pack on every clone."

        {false, msg}

      other ->
        {false, "[perf] Unexpected result from filter clone: #{inspect(other)}"}
    end
  end

  # If filter isn't supported, lazy mode will also fail somewhere —
  # but where? Document the exact failure shape so we know whether
  # exgit's lazy path is dead at clone time or at first-read time
  # against this server.
  defp check_lazy_capability(ctx) do
    transport = make_transport(ctx)

    case Exgit.clone(transport, lazy: true) do
      {:error, reason} ->
        "[perf] `lazy: true` clone fails immediately: #{inspect(reason)}"

      {:ok, repo} ->
        # Clone succeeded (refs only). First read will trigger an
        # on-demand fetch which itself uses `filter: blob:none`
        # (fs.ex:446) — that's where it should die.
        sample = Enum.take_random(ctx.filenames, 1) |> hd()

        case Exgit.FS.read_path(repo, ctx.branch, sample) do
          {:error, reason} ->
            "[perf] `lazy: true` clone OK; first read fails: #{inspect(reason)}"

          {:ok, _, _} ->
            "[perf] `lazy: true` clone + first read OK — server tolerates partial fetch?"
        end
    end
  end

  # --- Mode benchmarks ---

  defp bench_eager(ctx, n) do
    IO.puts("\n--- eager mode (#{n} iterations) ---")

    samples =
      for _ <- 1..n do
        transport = make_transport(ctx)
        {us, {:ok, repo}} = :timer.tc(fn -> Exgit.clone(transport) end)
        {us, eager_object_count(repo)}
      end

    {clone_times, obj_counts} = Enum.unzip(samples)

    IO.puts("[perf] eager clone time:   #{summarize(clone_times)}")

    IO.puts(
      "[perf] eager object count: #{format_count(obj_counts)} (expected #{@file_count + 2})"
    )

    %{mode: :eager, clone_us: clone_times, objects: obj_counts}
  end

  defp bench_partial(ctx, mode, clone_n, read_n) do
    label = mode_label(mode)
    IO.puts("\n--- #{label} mode (#{clone_n} clones × #{read_n} reads each) ---")

    iterations =
      for _ <- 1..clone_n do
        transport = make_transport(ctx)
        clone_opts = clone_opts_for(mode)

        {clone_us, {:ok, repo}} = :timer.tc(fn -> Exgit.clone(transport, clone_opts) end)
        bootstrap_bytes = repo.object_store.cache_bytes

        sample = Enum.take_random(ctx.filenames, read_n)

        {read_times_rev, repo} =
          Enum.reduce(sample, {[], repo}, fn filename, {acc, repo} ->
            {us, {:ok, {_mode, _blob}, repo}} =
              :timer.tc(fn -> Exgit.FS.read_path(repo, ctx.branch, filename) end)

            {[us | acc], repo}
          end)

        read_us = Enum.reverse(read_times_rev)

        %{
          clone_us: clone_us,
          bootstrap_bytes: bootstrap_bytes,
          read_us: read_us,
          final_bytes: repo.object_store.cache_bytes
        }
      end

    clone_times = Enum.map(iterations, & &1.clone_us)
    bootstrap_bytes_list = Enum.map(iterations, & &1.bootstrap_bytes)
    final_bytes_list = Enum.map(iterations, & &1.final_bytes)
    first_reads = Enum.map(iterations, &hd(&1.read_us))
    warm_reads = Enum.flat_map(iterations, &tl(&1.read_us))
    all_reads = Enum.flat_map(iterations, & &1.read_us)

    IO.puts("[perf] clone time:      #{summarize(clone_times)}")
    IO.puts("[perf] bootstrap bytes: #{format_bytes(bootstrap_bytes_list)}")
    IO.puts("[perf] final bytes:     #{format_bytes(final_bytes_list)} (after #{read_n} reads)")
    IO.puts("[perf] read #1 (cold):  #{summarize(first_reads)}")
    IO.puts("[perf] reads 2..#{read_n} (warm): #{summarize(warm_reads)}")
    IO.puts("[perf] all reads:       #{summarize(all_reads)}")

    %{
      mode: mode,
      clone_us: clone_times,
      bootstrap_bytes: bootstrap_bytes_list,
      final_bytes: final_bytes_list,
      first_read_us: first_reads,
      warm_read_us: warm_reads,
      all_read_us: all_reads
    }
  end

  defp clone_opts_for(:filter_blob_none), do: [filter: {:blob, :none}]
  defp clone_opts_for(:lazy), do: [lazy: true]

  defp mode_label(:filter_blob_none), do: "filter:{:blob, :none}"
  defp mode_label(:lazy), do: "lazy: true"

  # --- Summary ---

  defp print_summary(eager, filter, lazy) do
    IO.puts("\n========== Summary ==========")

    header = pad_row(["mode", "clone p50", "clone p95", "warm read p50", "warm read p95"])
    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    print_mode_row("eager", eager)
    if filter, do: print_mode_row("filter:{:blob, :none}", filter)
    if lazy, do: print_mode_row("lazy: true", lazy)

    IO.puts("")
  end

  defp print_mode_row(label, stats) do
    clone_p50 = ms_str(percentile(stats.clone_us, 50))
    clone_p95 = ms_str(percentile(stats.clone_us, 95))

    {read_p50, read_p95} =
      case Map.get(stats, :warm_read_us) do
        nil -> {"-", "-"}
        [] -> {"-", "-"}
        warm -> {ms_str(percentile(warm, 50)), ms_str(percentile(warm, 95))}
      end

    IO.puts(pad_row([label, clone_p50, clone_p95, read_p50, read_p95]))
  end

  defp pad_row(cols) do
    widths = [22, 12, 12, 16, 16]

    cols
    |> Enum.zip(widths)
    |> Enum.map_join(" ", fn {col, w} -> String.pad_trailing(col, w) end)
  end

  # --- Stats helpers ---

  defp summarize([]), do: "n=0"

  defp summarize(samples) do
    n = length(samples)
    p50 = ms_str(percentile(samples, 50))
    p95 = ms_str(percentile(samples, 95))
    p99 = ms_str(percentile(samples, 99))
    "n=#{n} p50=#{p50} p95=#{p95} p99=#{p99}"
  end

  defp percentile([_ | _] = samples, p) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    idx = trunc(:math.ceil(p / 100 * n)) - 1
    idx = max(0, min(n - 1, idx))
    Enum.at(sorted, idx)
  end

  defp ms_str(us) when is_integer(us), do: "#{us_to_ms(us)} ms"
  defp ms_str(other), do: to_string(other)

  defp us_to_ms(us) when is_integer(us), do: Float.round(us / 1000, 1)

  defp format_bytes(byte_list) do
    nums = Enum.reject(byte_list, &is_nil/1)

    case nums do
      [] -> "n/a"
      [single] -> "#{single}"
      _ -> "min=#{Enum.min(nums)} max=#{Enum.max(nums)} mean=#{mean(nums) |> round()}"
    end
  end

  defp format_count(count_list) do
    nums = Enum.reject(count_list, &is_nil/1)

    case nums do
      [] -> "n/a"
      [n] -> "#{n}"
      _ -> "min=#{Enum.min(nums)} max=#{Enum.max(nums)}"
    end
  end

  defp mean([]), do: 0
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  # --- exgit helpers ---

  defp eager_object_count(%Repository{object_store: %ObjectStore.Memory{objects: objs}}),
    do: map_size(objs)

  defp eager_object_count(_), do: nil

  defp count_cached_objects(%Promisor{cache: %ObjectStore.Memory{objects: objs}}),
    do: map_size(objs)

  defp count_cached_objects(_), do: :unknown

  defp make_transport(ctx) do
    Transport.HTTP.new(ctx.remote, auth: ArtifactsCreds.auth(ctx.read_token))
  end

  defp build_seed_commit(branch, file_count, file_bytes) do
    store = ObjectStore.Memory.new()

    {entries, store} =
      Enum.reduce(1..file_count, {[], store}, fn i, {acc, store} ->
        content = :crypto.strong_rand_bytes(file_bytes)
        {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new(content))
        filename = "file_#{String.pad_leading(Integer.to_string(i), 5, "0")}.bin"
        {[{"100644", filename, blob_sha} | acc], store}
      end)

    {:ok, tree_sha, store} = ObjectStore.put(store, Tree.new(entries))

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "Exgit Perf <test@exgit> 1700000000 +0000",
        committer: "Exgit Perf <test@exgit> 1700000000 +0000",
        message: "perf seed: #{file_count} x #{file_bytes}B\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)
    {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), branch, commit_sha, [])

    repo = %Repository{
      object_store: store,
      ref_store: ref_store,
      config: Exgit.Config.new(),
      path: nil
    }

    filenames = entries |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    {repo, commit_sha, filenames}
  end

  defp rand_hex(n), do: n |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
