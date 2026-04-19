defmodule Exgit.FS do
  @moduledoc """
  Path-oriented read/write access to a git repository — the interface an
  agent actually wants.

  All functions accept a `reference` that can be any of:
    * `"HEAD"` (or any ref name like `"refs/heads/main"`)
    * a raw commit binary SHA (20 bytes)
    * a raw tree binary SHA (20 bytes) — treated as the root tree

  Path separators are always forward slashes. Leading/trailing slashes
  are tolerated; `""` and `"/"` refer to the root tree.

  ## Threaded vs streaming

  **Strict operations** (`read_path/3`, `ls/3`, `stat/3`, `write_path/4`,
  `prefetch/3`) return a tagged triple `{:ok, result, repo}` so that
  any object-store state grown during the call (e.g. lazy cache
  population from `Promisor.resolve/2`) is visible to subsequent calls:

      {:ok, {_mode, blob1}, repo} = FS.read_path(repo, "HEAD", "a.ex")
      {:ok, {_mode, blob2}, repo} = FS.read_path(repo, "HEAD", "b.ex")

  **Streaming operations** (`walk/2`, `grep/4`) return lazy enumerables
  and use pure `ObjectStore.get/2`. They do NOT fetch missing objects
  from a promisor. Prime the cache first with `prefetch/3` if needed.
  """

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository}
  alias Exgit.ObjectStore.Promisor

  @type ref :: String.t() | binary()
  @type path :: String.t()
  @type stat :: %{type: :blob | :tree, mode: String.t(), size: non_neg_integer() | nil}

  @doc """
  Read the blob at `path`. Returns `{:ok, {mode, %Blob{}}, repo}` or
  `{:error, reason}`. The returned `repo` reflects any cache growth
  triggered during resolution.

  ## Options

    * `:resolve_lfs_pointers` (default `false`) — when `true`, blobs
      detected as git-lfs pointer files are returned as
      `{:ok, {mode, {:lfs_pointer, info}}, repo}` instead of
      `{:ok, {mode, %Blob{}}, repo}`. `info` is a map with
      `:oid`, `:size`, and `:raw` (the original pointer bytes).

      An agent reading blobs without this flag against an
      LFS-using repo will silently receive ~130-byte pointer
      text as if it were file content — a correctness cliff.
      See `Exgit.LFS` for detection details.

  """
  @spec read_path(Repository.t(), ref(), path(), keyword()) ::
          {:ok, {String.t(), Blob.t() | {:lfs_pointer, Exgit.LFS.pointer_info()}},
           Repository.t()}
          | {:error, :not_found | :not_a_blob | term()}
  def read_path(%Repository{} = repo, reference, path, opts \\ []) do
    resolve_lfs? = Keyword.get(opts, :resolve_lfs_pointers, false)

    Exgit.Telemetry.span(
      [:exgit, :fs, :read_path],
      %{reference: reference, path: path},
      fn ->
        with {:ok, tree_sha, repo} <- resolve_tree(repo, reference),
             {:ok, {mode, sha}, repo} <- walk_path(repo, tree_sha, normalize_path(path)),
             {:ok, obj, repo} <- fetch_object(repo, sha) do
          wrap_blob(obj, mode, repo, resolve_lfs?)
        end
      end
    )
  end

  # Post-process a fetched object into the `read_path` return shape.
  # Split out so the main `with` chain stays flat; credo flags the
  # in-line nested `case + if + case` otherwise.
  defp wrap_blob(%Blob{data: data} = b, mode, repo, true = _resolve_lfs?) do
    case Exgit.LFS.parse(data) do
      {:ok, info} -> {:ok, {mode, {:lfs_pointer, info}}, repo}
      {:error, _} -> {:ok, {mode, b}, repo}
    end
  end

  defp wrap_blob(%Blob{} = b, mode, repo, false), do: {:ok, {mode, b}, repo}
  defp wrap_blob(_other, _mode, _repo, _), do: {:error, :not_a_blob}

  @type line_range :: pos_integer() | Range.t() | [pos_integer() | Range.t()]

  @doc """
  Read a slice of `path` at `reference`, returning only the lines
  within `line_range`.

  `line_range` is 1-indexed and accepts:

    * `N` — a single line number.
    * `first..last` — inclusive range (step must be 1).
    * a list of any of the above.

  Returns `{:ok, [{line_number, line}], repo}`. Line numbers match
  `FS.grep/4`'s convention:

    * trailing `\\n` does NOT create a phantom empty line;
    * a file not ending in `\\n` still counts its partial last line;
    * an empty file has zero lines.

  Requested lines that fall outside the file are silently dropped
  (so `read_lines(repo, ref, path, 1..1000)` returns up to as many
  lines as the file has, rather than erroring). Duplicate or
  overlapping ranges in a list-form range are deduplicated, and
  returned lines are sorted ascending.

  ## Errors

    * `{:error, :not_found}` — path missing
    * `{:error, :not_a_blob}` — path is a directory
    * `{:error, {:invalid_line_range, term()}}` — unparseable
      range (zero/negative line numbers, non-unit step, etc.)

  ## Why not just `read_path` and slice?

  For a 10k-line source file, `read_path` materializes the full
  decompressed blob and the caller then does the line splitting
  and binary_parts. This function does one decompress + one
  newline scan + O(requested_lines) binary_parts — same result,
  bounded work per call. It also composes with `grep` +
  `:context`: grep can give you a match and narrow context;
  `read_lines` can give you wider context only when the agent
  asks.

  ## Examples

      {:ok, [{42, "def foo do"}], _repo} =
        FS.read_lines(repo, "HEAD", "lib/a.ex", 42)

      {:ok, lines, _repo} =
        FS.read_lines(repo, "HEAD", "lib/a.ex", 10..20)

      {:ok, lines, _repo} =
        FS.read_lines(repo, "HEAD", "lib/a.ex", [1, 10..12, 100])
  """
  @spec read_lines(Repository.t(), ref(), path(), line_range()) ::
          {:ok, [{pos_integer(), String.t()}], Repository.t()}
          | {:error, term()}
  def read_lines(%Repository{} = repo, reference, path, line_range) do
    with {:ok, line_nums} <- normalize_line_range(line_range),
         {:ok, tree_sha, repo} <- resolve_tree(repo, reference),
         {:ok, {_mode, sha}, repo} <- walk_path(repo, tree_sha, normalize_path(path)),
         {:ok, obj, repo} <- fetch_object(repo, sha) do
      case obj do
        %Blob{data: data} ->
          {:ok, slice_lines(data, line_nums), repo}

        _ ->
          {:error, :not_a_blob}
      end
    end
  end

  # Normalize a line_range argument into a sorted-unique list of
  # positive line numbers, or a tagged error.
  defp normalize_line_range(n) when is_integer(n) and n >= 1, do: {:ok, [n]}

  defp normalize_line_range(first..last//1) when first >= 1 and last >= first do
    {:ok, Enum.to_list(first..last//1)}
  end

  # Elixir synthesizes `first..last` with step -1 when first > last.
  # We accept that as an empty range (same semantics as `sed -n 'N,Mp'`
  # when N > M), not an error.
  defp normalize_line_range(first..last//-1) when first >= 1 and last <= first, do: {:ok, []}

  defp normalize_line_range(items) when is_list(items) do
    result =
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case normalize_line_range(item) do
          {:ok, nums} -> {:cont, {:ok, nums ++ acc}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, nums} -> {:ok, nums |> Enum.uniq() |> Enum.sort()}
      err -> err
    end
  end

  defp normalize_line_range(other), do: {:error, {:invalid_line_range, other}}

  defp slice_lines(_data, []), do: []

  defp slice_lines(data, line_nums) do
    newlines = newline_offsets(data)
    total = count_lines(data, newlines)

    line_nums
    |> Enum.filter(&(&1 <= total))
    |> Enum.map(fn n -> {n, line_contents(data, newlines, n)} end)
  end

  @doc """
  List entries of the directory at `path`. Returns `{:ok, entries, repo}`.
  """
  @spec ls(Repository.t(), ref(), path()) ::
          {:ok, [{String.t(), String.t(), binary()}], Repository.t()}
          | {:error, term()}
  def ls(%Repository{} = repo, reference, path) do
    Exgit.Telemetry.span(
      [:exgit, :fs, :ls],
      %{reference: reference, path: path},
      fn ->
        case do_ls(repo, reference, path) do
          {:ok, entries, _repo} = result -> {:span, result, %{entry_count: length(entries)}}
          other -> {:span, other, %{entry_count: 0}}
        end
      end
    )
  end

  defp do_ls(%Repository{} = repo, reference, path) do
    with {:ok, tree_sha, repo} <- resolve_tree(repo, reference) do
      segments = normalize_path(path)

      case segments do
        [] ->
          with {:ok, %Tree{entries: entries}, repo} <- fetch_object(repo, tree_sha) do
            {:ok, entries, repo}
          end

        _ ->
          case walk_path(repo, tree_sha, segments) do
            {:ok, {"40000", sha}, repo} ->
              with {:ok, %Tree{entries: entries}, repo} <- fetch_object(repo, sha) do
                {:ok, entries, repo}
              end

            {:ok, _, _} ->
              {:error, :not_a_tree}

            err ->
              err
          end
      end
    end
  end

  @doc """
  Stat the path. Returns `{:ok, stat, repo}`.
  """
  @spec stat(Repository.t(), ref(), path()) :: {:ok, stat(), Repository.t()} | {:error, term()}
  def stat(%Repository{} = repo, reference, path) do
    with {:ok, tree_sha, repo} <- resolve_tree(repo, reference) do
      segments = normalize_path(path)

      case segments do
        [] ->
          {:ok, %{type: :tree, mode: "40000", size: nil}, repo}

        _ ->
          with {:ok, {mode, sha}, repo} <- walk_path(repo, tree_sha, segments),
               {:ok, obj, repo} <- fetch_object(repo, sha) do
            case obj do
              %Blob{data: d} -> {:ok, %{type: :blob, mode: mode, size: byte_size(d)}, repo}
              %Tree{} -> {:ok, %{type: :tree, mode: mode, size: nil}, repo}
              _ -> {:error, :unknown_type}
            end
          end
      end
    end
  end

  @doc """
  Return true if the path exists under the given reference.

  Does not return the updated repo — this is a boolean shortcut. If you
  care about the grown cache after the check, use `stat/3`.
  """
  @spec exists?(Repository.t(), ref(), path()) :: boolean()
  def exists?(%Repository{} = repo, reference, path) do
    case stat(repo, reference, path) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  @doc """
  Prefetch trees reachable from `reference` (and optionally all
  blobs) into the object store.

  Options:

    * `:blobs` — when `true`, fetch blobs in addition to trees. When
      the call fetches blobs AND the repo is `:lazy`, the returned
      repo's `:mode` flips to `:eager` because every reachable object
      from `reference` is now resident and streaming ops can proceed
      without further transport calls. When `blobs: false`, mode is
      unchanged.

  Prefer `Exgit.Repository.materialize/2` for the one-shot
  "lazy-to-eager" conversion; `prefetch/3` is the progressive
  variant that lets you stage trees and blobs independently.
  """
  @spec prefetch(Repository.t(), ref(), keyword()) ::
          {:ok, Repository.t()} | {:error, term()}
  def prefetch(%Repository{} = repo, reference, opts \\ []) do
    include_blobs = Keyword.get(opts, :blobs, false)

    with {:ok, tree_sha, repo} <- resolve_tree(repo, reference) do
      prefetched = prefetch_tree(repo, tree_sha, include_blobs)

      # After a full prefetch (trees + blobs) every object reachable
      # from `reference` is resident in the Promisor cache, so the
      # repo is functionally eager for streaming ops.
      new_mode = if include_blobs and repo.mode == :lazy, do: :eager, else: prefetched.mode

      {:ok, %{prefetched | mode: new_mode}}
    end
  end

  defp prefetch_tree(repo, tree_sha, include_blobs) do
    case fetch_object(repo, tree_sha) do
      {:ok, %Tree{entries: entries}, repo} ->
        Enum.reduce(entries, repo, fn {mode, _name, sha}, repo ->
          cond do
            mode == "40000" -> prefetch_tree(repo, sha, include_blobs)
            include_blobs -> elem(fetch_object(repo, sha), 2)
            true -> repo
          end
        end)

      _ ->
        repo
    end
  end

  @doc """
  Lazy `{path, blob_sha}` stream of every file reachable from the given
  reference's tree.

  This is a streaming operation — it does NOT grow the object store
  cache on a lazy repo. Prefetch first if needed.
  """
  @spec walk(Repository.t(), ref()) :: Enumerable.t()
  def walk(%Repository{} = repo, reference) do
    :ok = require_eager!(repo, :walk)
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:exgit, :fs, :walk, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      %{reference: reference}
    )

    count = :counters.new(1, [])

    # Thread the updated repo through the stream's state tuple —
    # `{repo, stack}`. Resolving `reference` can grow a lazy repo's
    # Promisor cache (e.g. by fetching the commit object on-demand);
    # without carrying that growth forward, every single read during
    # the walk could trigger its own network fetch.
    #
    # Before this fix, `fn -> case resolve_tree(repo, reference) do
    # {:ok, sha, _repo} -> ...` discarded the grown repo, so a
    # `FS.walk` on a lazy repo that didn't pre-cache the commit
    # would network-fetch on EVERY walk — ~7 seconds per walk for a
    # 1400-file repo against GitHub. Now the grown repo lives in
    # the stream state, and subsequent reads come from the cache.
    Stream.resource(
      fn ->
        case resolve_tree(repo, reference) do
          {:ok, sha, updated_repo} -> {updated_repo, [{"", sha}]}
          _ -> {repo, []}
        end
      end,
      fn
        {_r, []} ->
          {:halt, :done}

        {r, [{prefix, tree_sha} | rest]} ->
          {emits, new_stack} = expand_pure(r, prefix, tree_sha, rest)
          :counters.add(count, 1, length(emits))
          {emits, {r, new_stack}}
      end,
      fn _ ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:exgit, :fs, :walk, :stop],
          %{duration: duration, monotonic_time: System.monotonic_time()},
          %{reference: reference, file_count: :counters.get(count, 1)}
        )
      end
    )
  end

  @doc """
  Glob paths matching `pattern`. Streaming; does not grow the cache.
  """
  @spec glob(Repository.t(), ref(), String.t()) :: {:ok, [String.t()]}
  def glob(%Repository{} = repo, reference, pattern) do
    regex = compile_glob(pattern)

    paths =
      walk(repo, reference)
      |> Stream.map(&elem(&1, 0))
      |> Stream.filter(&Regex.match?(regex, &1))
      |> Enum.sort()

    {:ok, paths}
  end

  @type grep_match :: %{
          required(:path) => String.t(),
          required(:line_number) => pos_integer(),
          required(:line) => String.t(),
          required(:match) => String.t(),
          optional(:context_before) => [{pos_integer(), String.t()}],
          optional(:context_after) => [{pos_integer(), String.t()}]
        }

  @doc """
  Stream grep over the blobs reachable from `reference`. Streaming; does
  not grow the cache.

  ## Options

    * `:path` — glob restricting which paths are searched. Default `"**"`.
    * `:max_count` — stop after N matches (across all files). Default
      unlimited.
    * `:include_binary` — include binary blobs. Default `false`; binary
      detection is a NUL-byte heuristic on the first 8 KB.
    * `:case_insensitive` — `"i"` regex flag. Default `false`.
    * `:max_concurrency` — parallel worker count. Default `1`.

  ### Context

    * `:context` — symmetric context, N lines before + after each match.
      Sets `:before` and `:after` to the same value.
    * `:before` — lines of context BEFORE each match.
    * `:after` — lines of context AFTER each match.

  When any of `:context`, `:before`, or `:after` is positive, result
  rows gain `:context_before` and `:context_after` fields, each a list
  of `{line_number, line}` tuples. Lists may be empty when a match is
  near the start or end of a file. When no context is requested, those
  fields are absent from the returned map — existing callers pattern-
  matching `%{path: _, line_number: _, line: _, match: _}` continue to
  work.

  When two matches in the same file are closer than `before + after`
  lines, their context ranges overlap. Each match emits its own
  independent row; the consumer may deduplicate by line number.
  """
  @spec grep(Repository.t(), ref(), String.t() | Regex.t(), keyword()) :: Enumerable.t()
  def grep(%Repository{} = repo, reference, pattern, opts \\ []) do
    :ok = require_eager!(repo, :grep)
    regex = compile_grep_pattern(pattern, opts)
    path_glob = Keyword.get(opts, :path, "**")
    path_regex = compile_glob(path_glob)
    max_count = Keyword.get(opts, :max_count)
    include_binary = Keyword.get(opts, :include_binary, false)
    context = parse_context_opts(opts)

    # Parallelism knob. Defaults to `1` (sequential). In-memory
    # grep over compressed blobs is CPU-light: regex scan against
    # ~10 KB of code takes microseconds. Task.async_stream's
    # per-file spawn + message-passing overhead is ~50-100 µs per
    # item, which DOMINATES the work being parallelized for
    # typical code-search workloads (1k-file repo → parallel is
    # 20× SLOWER than sequential in our measurements).
    #
    # Parallelism IS a win when per-file work is substantial:
    # large blobs (100 KB+), complex regex, or I/O-bound stores.
    # Callers with that profile opt in by passing
    # `max_concurrency: :schedulers` (uses
    # System.schedulers_online()) or an integer.
    max_concurrency =
      Keyword.get(opts, :max_concurrency, 1) |> resolve_concurrency()

    start_time = System.monotonic_time()
    match_counter = :counters.new(1, [])
    file_counter = :counters.new(1, [])
    bytes_counter = :counters.new(1, [])

    metadata = %{
      reference: reference,
      pattern: pattern_repr(pattern),
      path_glob: path_glob,
      max_concurrency: max_concurrency
    }

    :telemetry.execute(
      [:exgit, :fs, :grep, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      metadata
    )

    # Per-file work factored out so it can run either in the main
    # process (sequential path) or in a worker Task (parallel
    # path). Counters are `:counters` refs — concurrent-safe by
    # design, which is the main reason this parallelization is so
    # mechanical.
    scan_file = fn {path, sha} ->
      case ObjectStore.get(repo.object_store, sha) do
        {:ok, %Blob{data: data}} ->
          :counters.add(file_counter, 1, 1)
          :counters.add(bytes_counter, 1, byte_size(data))

          if include_binary or not binary_content?(data) do
            matches = matches_in(path, data, regex, context)
            :counters.add(match_counter, 1, length(matches))
            matches
          else
            []
          end

        _ ->
          []
      end
    end

    stream =
      walk(repo, reference)
      |> Stream.filter(fn {path, _sha} -> Regex.match?(path_regex, path) end)
      |> dispatch_scan(scan_file, max_concurrency)

    emit_stop = fn ->
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:exgit, :fs, :grep, :stop],
        %{duration: duration, monotonic_time: System.monotonic_time()},
        Map.merge(metadata, %{
          match_count: :counters.get(match_counter, 1),
          files_scanned: :counters.get(file_counter, 1),
          bytes_scanned: :counters.get(bytes_counter, 1)
        })
      )
    end

    emitted = :counters.new(1, [])

    emit_once = fn ->
      if :counters.get(emitted, 1) == 0 do
        :counters.add(emitted, 1, 1)
        emit_stop.()
      end
    end

    wrapped =
      Stream.transform(
        stream,
        fn -> :ok end,
        fn match, acc -> {[match], acc} end,
        fn acc -> {[], acc} end,
        fn _acc -> emit_once.() end
      )

    if max_count, do: Stream.take(wrapped, max_count), else: wrapped
  end

  # Dispatch the per-file scan either sequentially (`max_concurrency:
  # 1`) or in parallel via `Task.async_stream`. The sequential path
  # avoids `Task.async_stream`'s per-item spawn+message overhead,
  # which dominates on tiny inputs (e.g. a repo with <10 files).
  defp dispatch_scan(paths_stream, scan_file, 1) do
    Stream.flat_map(paths_stream, scan_file)
  end

  defp dispatch_scan(paths_stream, scan_file, max_concurrency) do
    paths_stream
    |> Task.async_stream(scan_file,
      max_concurrency: max_concurrency,
      ordered: false,
      # File scans are pure-CPU + cache-local — a 30s timeout is
      # generous. Shorter than Task's default :infinity so a
      # runaway scan doesn't block the stream forever.
      timeout: 30_000,
      # On timeout or crash, drop the file and keep going rather
      # than killing the whole grep.
      on_timeout: :kill_task
    )
    |> Stream.flat_map(fn
      {:ok, matches} -> matches
      {:exit, _reason} -> []
    end)
  end

  # Resolve the :max_concurrency option to a positive integer.
  # `:schedulers` expands to System.schedulers_online() at runtime.
  # Numeric values are clamped to at least 1.
  defp resolve_concurrency(:schedulers), do: System.schedulers_online()
  defp resolve_concurrency(n) when is_integer(n) and n > 0, do: n
  defp resolve_concurrency(_), do: 1

  defp pattern_repr(%Regex{source: s}), do: "~r/#{s}/"
  defp pattern_repr(s) when is_binary(s), do: s

  @doc """
  Write `content` to `path`. Returns `{:ok, new_tree_sha, repo}`.
  """
  @spec write_path(Repository.t(), ref(), path(), binary(), keyword()) ::
          {:ok, binary(), Repository.t()} | {:error, term()}
  def write_path(%Repository{} = repo, reference, path, content, opts \\ []) do
    mode = Keyword.get(opts, :mode, "100644")
    segments = normalize_path(path)

    if segments == [] do
      {:error, :cannot_write_root}
    else
      with {:ok, tree_sha, repo} <- resolve_tree(repo, reference) do
        blob = Blob.new(content)
        {:ok, blob_sha, store} = ObjectStore.put(repo.object_store, blob)
        repo = %{repo | object_store: store}

        insert_blob_into_tree(repo, tree_sha, segments, mode, blob_sha)
      end
    end
  end

  defp insert_blob_into_tree(repo, tree_sha, [name], mode, blob_sha) do
    with {:ok, %Tree{entries: entries}, repo} <- fetch_object(repo, tree_sha) do
      new_entries =
        case Enum.find_index(entries, fn {_, n, _} -> n == name end) do
          nil -> entries ++ [{mode, name, blob_sha}]
          i -> List.replace_at(entries, i, {mode, name, blob_sha})
        end

      new_tree = Tree.new(new_entries)
      {:ok, sha, store} = ObjectStore.put(repo.object_store, new_tree)
      {:ok, sha, %{repo | object_store: store}}
    end
  end

  defp insert_blob_into_tree(repo, tree_sha, [dir | rest], mode, blob_sha) do
    with {:ok, %Tree{entries: entries}, repo} <- fetch_object(repo, tree_sha) do
      {child_sha_or_empty, other_entries} =
        case Enum.find(entries, fn {m, n, _} -> n == dir and m == "40000" end) do
          {_, _, sha} ->
            {{:existing, sha}, Enum.reject(entries, fn {_, n, _} -> n == dir end)}

          nil ->
            {:empty, Enum.reject(entries, fn {_, n, _} -> n == dir end)}
        end

      result =
        case child_sha_or_empty do
          {:existing, sha} -> insert_blob_into_tree(repo, sha, rest, mode, blob_sha)
          :empty -> insert_blob_into_empty(repo, rest, mode, blob_sha)
        end

      case result do
        {:ok, new_child_sha, repo} ->
          new_entries = other_entries ++ [{"40000", dir, new_child_sha}]
          new_tree = Tree.new(new_entries)
          {:ok, sha, store} = ObjectStore.put(repo.object_store, new_tree)
          {:ok, sha, %{repo | object_store: store}}

        err ->
          err
      end
    end
  end

  defp insert_blob_into_empty(repo, [name], mode, blob_sha) do
    tree = Tree.new([{mode, name, blob_sha}])
    {:ok, sha, store} = ObjectStore.put(repo.object_store, tree)
    {:ok, sha, %{repo | object_store: store}}
  end

  defp insert_blob_into_empty(repo, [dir | rest], mode, blob_sha) do
    # Recursive base cases (see above) are total — they pattern-match
    # `{:ok, sha, store} = ObjectStore.put(...)` unconditionally, so
    # this branch always receives `{:ok, _, _}`.
    {:ok, child_sha, repo} = insert_blob_into_empty(repo, rest, mode, blob_sha)
    tree = Tree.new([{"40000", dir, child_sha}])
    {:ok, sha, store} = ObjectStore.put(repo.object_store, tree)
    {:ok, sha, %{repo | object_store: store}}
  end

  # ----------------------------------------------------------------------
  # Internal: object fetch that threads the repo for Promisor-backed stores
  # ----------------------------------------------------------------------

  # Single lookup that grows the cache when the store is a Promisor.
  # Returns `{:ok, object, repo}` — always threads the repo so callers
  # can chain via `with`.
  defp fetch_object(%Repository{object_store: %Promisor{} = p} = repo, sha) do
    case Promisor.resolve(p, sha) do
      {:ok, obj, p2} ->
        {:ok, obj, %{repo | object_store: p2}}

      {:error, reason, p2} ->
        # Fetch-but-not-found or cache-overfull: the Promisor
        # grew its cache even though this specific lookup
        # didn't find the target. Discard the grown repo — FS
        # callers use the 2-tuple error shape, and a caller who
        # needs the sibling-object cache can call
        # `Promisor.resolve/2` directly.
        _ = p2
        {:error, reason}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_object(%Repository{object_store: store} = repo, sha) do
    case ObjectStore.get(store, sha) do
      {:ok, obj} -> {:ok, obj, repo}
      {:error, _} = err -> err
    end
  end

  # Resolve a reference to a TREE sha. Threads the repo in case the
  # resolution grew the cache.
  #
  # A 20-byte binary MIGHT be a SHA or a 20-char ASCII-printable ref
  # name. Disambiguate: if every byte is a printable-ASCII character
  # and the binary doesn't look like random hash output, try it as a
  # ref name FIRST; otherwise treat as a raw SHA. This avoids the
  # "`refs/heads/exactly_20chars` interpreted as SHA" footgun the
  # reviewer flagged (#41).
  defp resolve_tree(repo, reference) when is_binary(reference) and byte_size(reference) == 20 do
    cond do
      printable_ascii_ref?(reference) ->
        resolve_tree_as_refname(repo, reference)

      true ->
        case fetch_object(repo, reference) do
          {:ok, %Commit{} = c, repo} -> {:ok, Commit.tree(c), repo}
          {:ok, %Tree{}, repo} -> {:ok, reference, repo}
          {:ok, _, _repo} -> {:error, :not_a_commit_or_tree}
          {:error, _} = err -> err
        end
    end
  end

  defp resolve_tree(repo, reference) when is_binary(reference),
    do: resolve_tree_as_refname(repo, reference)

  # Extracted so both the 20-byte-printable branch and the general
  # string branch share the same "ref → commit/tree → tree-sha" path.
  # Accepts refs that point to a tree object directly (some workflows
  # persist tree SHAs as refs for intermediate state); previously the
  # string-ref branch rejected trees with :ref_points_to_tree_not_commit,
  # which was inconsistent with the raw-SHA branch.
  defp resolve_tree_as_refname(repo, reference) do
    # `RefStore.resolve/2` and `fetch_object/2` both return either
    # `{:ok, ...}` or `{:error, _}`, so the `with` else-block only
    # needs to catch the error shape. Dialyzer rejects a fallback
    # `_ -> ...` clause here as dead code.
    with {:ok, sha} <- RefStore.resolve(repo.ref_store, reference),
         {:ok, obj, repo} <- fetch_object(repo, sha) do
      case obj do
        %Commit{} = c -> {:ok, Commit.tree(c), repo}
        %Tree{} -> {:ok, sha, repo}
        _ -> {:error, :not_a_commit_or_tree}
      end
    end
  end

  # True if every byte in the 20-byte binary is a printable-ASCII
  # character AND at least one byte is NOT in the hex alphabet. A
  # binary that's all hex digits AND exactly 20 bytes is unusual as
  # a ref name (too long for a branch, no slashes) — treat as a SHA.
  # Real ref names almost always contain `/` anyway; the branch
  # is just defensive for callers who pass e.g. `"HEAD"` padded to
  # 20 bytes somehow.
  defp printable_ascii_ref?(<<_::binary-size(20)>> = bin) do
    printable? = for <<b <- bin>>, reduce: true, do: (acc -> acc and b in 0x20..0x7E)

    has_non_hex? =
      for <<b <- bin>>,
        reduce: false,
        do: (acc -> acc or not (b in ?0..?9 or b in ?a..?f or b in ?A..?F))

    printable? and has_non_hex?
  end

  defp printable_ascii_ref?(_), do: false

  # Traverse tree entries by path segments; return the {mode, sha} of
  # the final segment's entry. Threads the repo.
  defp walk_path(repo, sha, []), do: {:ok, {"40000", sha}, repo}

  defp walk_path(repo, sha, [name | rest]) do
    case fetch_object(repo, sha) do
      {:ok, %Tree{entries: entries}, repo} ->
        case Enum.find(entries, fn {_m, n, _} -> n == name end) do
          {mode, ^name, entry_sha} when rest == [] ->
            {:ok, {mode, entry_sha}, repo}

          {_mode, ^name, entry_sha} ->
            walk_path(repo, entry_sha, rest)

          nil ->
            {:error, :not_found}
        end

      {:error, _} = err ->
        err

      _ ->
        {:error, :not_found}
    end
  end

  # Pure-read variant used by streaming ops (walk/grep). Returns either
  # the expanded entries or an empty list on lookup failure.
  defp expand_pure(repo, prefix, tree_sha, stack) do
    case ObjectStore.get(repo.object_store, tree_sha) do
      {:ok, %Tree{entries: entries}} ->
        {blobs, subs} =
          Enum.split_with(entries, fn {mode, _, _} -> mode != "40000" end)

        blob_emits = for {_mode, name, sha} <- blobs, do: {join(prefix, name), sha}
        sub_pushes = for {_mode, name, sha} <- subs, do: {join(prefix, name), sha}

        {blob_emits, sub_pushes ++ stack}

      _ ->
        {[], stack}
    end
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  defp join("", name), do: name
  defp join(prefix, name), do: prefix <> "/" <> name

  defp normalize_path(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> String.split("/", trim: true)
  end

  # Streaming FS operations (`walk/2`, `grep/4`) use pure
  # `ObjectStore.get/2` and do NOT grow a Promisor cache. Running
  # them on a `:lazy` repo would either trigger unbounded
  # mid-iteration fetches or silently skip missing objects — both
  # worse than a clear error. We raise `ArgumentError` with a
  # pointer at `FS.prefetch/3` (populate in place) or
  # `Repository.materialize/2` (convert to `:eager`).
  #
  # `:lazy` is the one source of truth; `FS` does NOT poke at the
  # object_store struct shape.
  defp require_eager!(%Repository{mode: :eager}, _op), do: :ok

  defp require_eager!(%Repository{mode: :lazy}, op) do
    raise ArgumentError,
          "Exgit.FS.#{op}/* requires an :eager repository; this one is :lazy. " <>
            "Call `Exgit.Repository.materialize(repo, ref)` to convert in one " <>
            "step (recommended), or `Exgit.FS.prefetch(repo, ref, blobs: true)` " <>
            "to populate the Promisor cache in place. Streaming ops use pure " <>
            "reads; silent empty results would be worse than this error."
  end

  defp compile_grep_pattern(%Regex{} = r, _opts), do: r

  defp compile_grep_pattern(str, opts) when is_binary(str) do
    flags = if Keyword.get(opts, :case_insensitive, false), do: "i", else: ""
    Regex.compile!(Regex.escape(str), flags)
  end

  defp binary_content?(data) do
    head = binary_part(data, 0, min(8 * 1024, byte_size(data)))
    :binary.match(head, <<0>>) != :nomatch
  end

  # Scan a blob for regex matches and return one result map per
  # match. Two-phase fast path:
  #
  #   1. `Regex.scan(regex, data, return: :index)` identifies match
  #      offsets in a single pass over the whole blob. If there
  #      are no matches (the 99%-of-files common case for a code
  #      search against a large codebase), we're done — no line
  #      splitting, no per-line regex work.
  #
  #   2. For matched files, precompute line-start offsets once
  #      via `:binary.matches(data, "\n")`, then for each match
  #      look up the containing line via binary search.
  #
  # On pyex (275 files, 3 MB, 2 matches) this is ~13× faster than
  # the previous approach (split every file into lines via regex,
  # then scan each line independently). The speedup grows with
  # repo size because the no-match branch short-circuits before
  # any per-line work.
  #
  # The returned shape matches what callers expect:
  # `%{path, line_number, line, match}`.
  defp matches_in(path, data, regex, context) do
    case Regex.scan(regex, data, return: :index, capture: :first) do
      [] ->
        []

      matches ->
        # One-shot scan of all newline offsets. `:binary.matches/2`
        # runs in native code and is O(bytes) with a low constant —
        # significantly faster than `String.split/2` with a regex
        # when we only need offsets.
        newline_positions = newline_offsets(data)
        total_lines = count_lines(data, newline_positions)

        for [{pos, len}] <- matches do
          line_number = line_at(newline_positions, pos)
          line_text = line_contents(data, newline_positions, line_number)
          matched = binary_part(data, pos, len)

          base = %{path: path, line_number: line_number, line: line_text, match: matched}

          case context do
            {0, 0} ->
              base

            {before_n, after_n} ->
              Map.merge(base, %{
                context_before:
                  context_range(data, newline_positions, line_number, -before_n, -1),
                context_after:
                  context_range(
                    data,
                    newline_positions,
                    line_number,
                    1,
                    after_n,
                    total_lines
                  )
              })
          end
        end
    end
  end

  # Build a list of {line_number, line} tuples for lines offset by
  # `first_delta..last_delta` from `anchor`, clamped to [1, ∞). The
  # 6-arity variant additionally clamps to total_lines on the top
  # end. Used for context_before (no top clamp needed; negative
  # deltas can never exceed total_lines) and context_after (top
  # clamp required).
  defp context_range(data, newlines, anchor, first_delta, last_delta) do
    for delta <- first_delta..last_delta//1,
        ln = anchor + delta,
        ln >= 1 do
      {ln, line_contents(data, newlines, ln)}
    end
  end

  defp context_range(data, newlines, anchor, first_delta, last_delta, total_lines) do
    for delta <- first_delta..last_delta//1,
        ln = anchor + delta,
        ln >= 1 and ln <= total_lines do
      {ln, line_contents(data, newlines, ln)}
    end
  end

  # Extract :context / :before / :after from opts into a normalized
  # {before_lines, after_lines} tuple. `:context` sets both;
  # `:before`/`:after` override individually. Negative or invalid
  # values are treated as 0.
  defp parse_context_opts(opts) do
    c = opts |> Keyword.get(:context, 0) |> max_nonneg()
    b = opts |> Keyword.get(:before, c) |> max_nonneg()
    a = opts |> Keyword.get(:after, c) |> max_nonneg()
    {b, a}
  end

  defp max_nonneg(n) when is_integer(n) and n > 0, do: n
  defp max_nonneg(_), do: 0

  # Number of lines in `data` matching git's convention: lines are
  # delimited by \n, a trailing \n does NOT create a phantom empty
  # line, and a file lacking a trailing \n still has the partial
  # last line counted.
  #
  #   ""                 -> 0 lines
  #   "a"                -> 1 line  (no trailing \n)
  #   "a\n"              -> 1 line  (trailing \n swallowed)
  #   "a\nb"             -> 2 lines
  #   "a\nb\n"           -> 2 lines
  #   "\n"               -> 1 line  (one empty line)
  defp count_lines(<<>>, _newlines), do: 0

  defp count_lines(data, newlines) do
    # `newlines` = [-1 | actual_newline_offsets]. Strip the sentinel
    # to count real newlines.
    real_nls = length(newlines) - 1

    if :binary.last(data) == ?\n do
      real_nls
    else
      real_nls + 1
    end
  end

  # Returns a list of byte offsets of newline characters in `data`,
  # preceded by -1 and followed by byte_size(data) to act as
  # sentinels so `line_at/2` can compute 1-based line numbers
  # without special-casing BOF/EOF.
  defp newline_offsets(data) do
    matches = :binary.matches(data, "\n")
    [-1 | Enum.map(matches, &elem(&1, 0))]
  end

  # Which 1-based line does byte `pos` land on?
  # `newlines` is [-1, pos0, pos1, ...]; the line number is the
  # count of newline offsets that are strictly less than `pos`.
  # Linear scan is fine — for most files there are <1000 newlines
  # and we're only looking up line numbers for actual matches.
  defp line_at(newlines, pos) do
    Enum.count(newlines, fn nl -> nl < pos end)
  end

  # Extract the content of `line_number` (1-based) from `data`
  # given the precomputed newline-offsets list. Handles the
  # trailing-line case (file doesn't end in newline) gracefully.
  defp line_contents(data, newlines, line_number) do
    # `newlines` is [-1, nl_0, nl_1, ...]; line k starts at
    # newlines[k-1]+1 and ends at newlines[k] (exclusive).
    start_idx = line_number - 1
    start_pos = Enum.at(newlines, start_idx, -1) + 1
    next_nl = Enum.at(newlines, line_number, byte_size(data))
    len = max(next_nl - start_pos, 0)
    binary_part(data, start_pos, len)
  end

  # Compile a glob pattern into a regex. Supports:
  #   *       — any chars except `/`
  #   **      — any chars including `/`
  #   **/     — zero or more path segments
  #   ?       — a single char except `/`
  #   {a,b,c} — alternation; each alternative is itself a glob
  #
  # Unclosed `{` is treated as a literal. Empty alternatives are
  # allowed (`{,.bak}` matches either empty or `.bak`). Nested braces
  # are not supported; the first `}` closes the group.
  #
  # Returns the Regex, falling back to an always-false regex if
  # the generated source fails to compile (shouldn't happen for any
  # legitimate glob but we return a tagged error rather than raising
  # on user input).
  defp compile_glob(pattern) do
    regex_src = pattern |> to_charlist() |> compile_glob_chars([]) |> IO.iodata_to_binary()

    case Regex.compile("^" <> regex_src <> "$") do
      {:ok, r} -> r
      {:error, _} -> ~r/$^/
    end
  end

  defp compile_glob_chars([], acc), do: Enum.reverse(acc)

  defp compile_glob_chars([?*, ?*, ?/ | rest], acc) do
    compile_glob_chars(rest, ["(?:.*/)?" | acc])
  end

  defp compile_glob_chars([?*, ?* | rest], acc) do
    compile_glob_chars(rest, [".*" | acc])
  end

  defp compile_glob_chars([?* | rest], acc) do
    compile_glob_chars(rest, ["[^/]*" | acc])
  end

  defp compile_glob_chars([?? | rest], acc) do
    compile_glob_chars(rest, ["[^/]" | acc])
  end

  defp compile_glob_chars([?{ | rest], acc) do
    case take_brace_group(rest) do
      {:ok, alternatives, after_brace} ->
        # Each alternative is itself a glob — recurse so `{*.a,*.b}`
        # works the same as the equivalent split-up patterns.
        alt_regex =
          Enum.map_join(alternatives, "|", fn alt ->
            alt |> compile_glob_chars([]) |> IO.iodata_to_binary()
          end)

        compile_glob_chars(after_brace, ["(?:" <> alt_regex <> ")" | acc])

      :no_close ->
        # Unclosed brace: emit the `{` as a literal and continue.
        compile_glob_chars(rest, [Regex.escape("{") | acc])
    end
  end

  defp compile_glob_chars([c | rest], acc) do
    compile_glob_chars(rest, [Regex.escape(<<c::utf8>>) | acc])
  end

  # Scan a brace group starting just after the opening `{`. Returns
  # `{:ok, alternatives, remaining_chars}` where `alternatives` is a
  # list of charlists, one per comma-separated option. `:no_close` if
  # the string ends before a matching `}`.
  defp take_brace_group(chars), do: take_brace_group(chars, [], [])

  defp take_brace_group([], _current, _alts), do: :no_close

  defp take_brace_group([?} | rest], current, alts) do
    {:ok, Enum.reverse([Enum.reverse(current) | alts]), rest}
  end

  defp take_brace_group([?, | rest], current, alts) do
    take_brace_group(rest, [], [Enum.reverse(current) | alts])
  end

  defp take_brace_group([c | rest], current, alts) do
    take_brace_group(rest, [c | current], alts)
  end
end
