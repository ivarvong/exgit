defmodule Exgit.Blame do
  # Silence Dialyzer false positives on MapSet opacity. Pattern
  # borrowed from Exgit.Walk / Exgit.Diff — the `seen` set is a
  # plain MapSet.t() but Dialyzer surfaces its internal
  # :sets/map union at cross-function call sites.
  @dialyzer :no_opaque

  @moduledoc """
  Per-line authorship attribution for a file at a ref.

  For each line of `path` at `ref`, `blame/3` returns the commit
  that most recently introduced or modified that line, plus the
  commit's author metadata.

  ## Semantics

  Follows `git blame --first-parent` semantics:

    * Walks only the first-parent chain. Merge commits are
      traversed by their first parent; contributions from merged
      branches are attributed to the merge commit itself if the
      line's first appearance on the first-parent chain is there.
    * No move/copy detection. Lines that moved or were copied
      between files are attributed to the commit that placed the
      line at its current path.
    * No rename following. If `path` was renamed at some commit
      in history, blame attributes everything before the rename
      to the rename commit.
    * Lines are compared by exact byte equality. Whitespace
      changes count as changes.

  The 80% version. Full `git blame` has ~15 years of heuristics
  (whitespace ignoring, `--ignore-revs`, patience diff, move +
  copy detection) that aren't implemented here. For agent
  workflows that want "who introduced this line?" this is
  sufficient; for deep forensics, shell out to real git.

  ## API

      {:ok, entries, repo} = Exgit.Blame.blame(repo, ref, path)

  Each entry:

      %{
        line_number: 1..N,
        line: "source text",
        commit_sha: <<20-byte raw sha>>,
        author_name: "Alice",
        author_email: "alice@example.com",
        author_time: 1_700_000_000,   # Unix seconds
        summary: "first line of commit message"
      }

  Returns `{:error, :not_found}` if `path` doesn't exist at
  `ref`, `{:error, :not_a_blob}` if it's a directory,
  `{:error, :unbounded_history}` if the walk exceeds
  `@max_commits_walked` (hostile-input guard).
  """

  alias Exgit.Diff.LineDiff
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.ObjectStore
  alias Exgit.ObjectStore.Promisor
  alias Exgit.RefStore
  alias Exgit.Repository

  # Safety cap on how far back we'll walk. Real repos average
  # tens to hundreds of commits per file; 100k is 10x-100x more
  # than any realistic blame would need and prevents a runaway
  # walk on a malformed commit chain.
  @max_commits_walked 100_000

  @type entry :: %{
          line_number: pos_integer(),
          line: String.t(),
          commit_sha: binary(),
          author_name: String.t(),
          author_email: String.t(),
          author_time: integer(),
          summary: String.t()
        }

  @doc """
  Produce per-line authorship attribution for `path` at `reference`.

  ## Options

    * `:auto_fetch` (default `true`) — when the repo is a
      `Promisor`-backed lazy clone, blame walks history and
      historical blob versions that `FS.prefetch/3` does not pull.
      With `auto_fetch: true`, blame transparently triggers a
      batched commit-graph fetch and a batched path-history blob
      fetch before starting the walk. The first blame call on a
      cold repo pays this one-time cost (typically 200-800 ms);
      subsequent calls are warm.

      With `auto_fetch: false`, blame does NOT trigger any network
      requests. If required objects aren't cached, blame truncates
      its walk at the first missing object and attributes remaining
      lines to the current commit. Useful when callers want
      predictable no-network behavior — they should call
      `FS.prefetch_history/2` explicitly beforehand.

  Regardless of the flag, every auto-fetch emits
  `[:exgit, :blame, :auto_fetch, :start]` and
  `[:exgit, :blame, :auto_fetch, :stop]` telemetry events so
  silent slowness is visible to operators.
  """
  @spec blame(Repository.t(), String.t() | binary(), String.t(), keyword()) ::
          {:ok, [entry()], Repository.t()} | {:error, term()}
  def blame(%Repository{} = repo, reference, path, opts \\ []) do
    auto_fetch? = Keyword.get(opts, :auto_fetch, true)

    with {:ok, commit_sha} <- resolve_commit(repo, reference),
         {:ok, repo} <- maybe_ensure_history(repo, commit_sha, auto_fetch?),
         {:ok, repo} <- maybe_ensure_path_blobs(repo, commit_sha, path, auto_fetch?),
         {:ok, target_lines} <- read_file_at_commit(repo, commit_sha, path) do
      # `pending` maps ORIGINAL target-file line index to the
      # current-commit's line index. Starts as identity (each line
      # in target is itself in the target commit's version).
      pending =
        target_lines
        |> Enum.with_index()
        |> Map.new(fn {_line, idx} -> {idx, idx} end)

      case walk(repo, commit_sha, path, pending, %{}, 0) do
        {:ok, attributions} ->
          {:ok, entries} = build_entries(repo, target_lines, attributions)
          {:ok, entries, repo}

        err ->
          err
      end
    end
  end

  defp maybe_ensure_history(repo, _commit_sha, false), do: {:ok, repo}

  defp maybe_ensure_history(repo, commit_sha, true) do
    ensure_history_available(repo, commit_sha)
  end

  defp maybe_ensure_path_blobs(repo, _commit_sha, _path, false), do: {:ok, repo}

  defp maybe_ensure_path_blobs(repo, commit_sha, path, true) do
    ensure_path_blobs_available(repo, commit_sha, path)
  end

  # For Promisor-backed repos, blame needs the commit graph to walk
  # ancestors. If the target commit's parent is missing from the
  # cache, trigger a one-shot `prefetch_history` to pull the commit
  # graph (commits + trees, no blobs — those are only needed for the
  # target commit's working tree, which prefetch/3 handles).
  #
  # This is lazy: we don't pay the history fetch unless blame is
  # actually called, and we only pay it once per Promisor (the second
  # blame call sees the cache populated and skips).
  #
  # Non-Promisor stores (Disk, Memory, eager) either have history
  # or don't; there's no fetch to do, so this is a no-op.
  defp ensure_history_available(%Repository{object_store: %Promisor{}} = repo, commit_sha) do
    case ObjectStore.get(repo.object_store, commit_sha) do
      {:ok, %Commit{} = commit} ->
        case Commit.parents(commit) do
          [] ->
            # Root commit — no history to fetch.
            {:ok, repo}

          [parent_sha | _] ->
            case ObjectStore.get(repo.object_store, parent_sha) do
              {:ok, _} ->
                # Parent already cached — history is likely
                # already populated (or at least populated enough
                # for this blame). Skip the fetch.
                {:ok, repo}

              {:error, _} ->
                # Parent missing — pull the commit graph.
                fetch_history_with_telemetry(repo, commit_sha)
            end
        end

      {:error, _} ->
        # Target commit itself missing; the outer `with` will
        # surface the error.
        {:ok, repo}
    end
  end

  defp ensure_history_available(repo, _commit_sha), do: {:ok, repo}

  # Wraps `FS.prefetch_history` in a telemetry span. Blame's implicit
  # fetches used to be invisible; now `[:exgit, :blame, :auto_fetch, :*]`
  # events fire around them so operators can see "ah, blame triggered
  # a 300ms history fetch" in their dashboards without guessing.
  defp fetch_history_with_telemetry(repo, commit_sha) do
    Exgit.Telemetry.span(
      [:exgit, :blame, :auto_fetch],
      %{phase: :history, commit_sha: commit_sha},
      fn ->
        case Exgit.FS.prefetch_history(repo, commit_sha) do
          {:ok, new_repo} = ok ->
            {:span, ok, %{cache_bytes: new_repo.object_store.cache_bytes}}

          {:error, reason} = err ->
            {:span, err, %{error: reason}}
        end
      end
    )
  end

  # For Promisor-backed repos, blame's walk needs to read the blob of
  # `path` at every commit in the first-parent chain. These historical
  # blobs are NOT fetched by `FS.prefetch(blobs: true)` — that call
  # only fetches blobs reachable from HEAD's tree. Historical versions
  # of the same path are distinct blob SHAs.
  #
  # Strategy: walk the first-parent chain using the commit graph
  # (which is cached after `ensure_history_available`), collect the
  # unique blob SHAs for `path` at each commit, and batch-fetch
  # any missing ones in a single `want <sha1> <sha2> ...` request.
  #
  # For a typical file (say README touched in 20 commits), this is
  # ~20 SHAs in one batched fetch instead of 20 sequential
  # on-demand fetches. Same idea as `FS.prefetch/3`'s batched fetch
  # but scoped to a specific path's blob history.
  #
  # Non-Promisor stores: no-op.
  defp ensure_path_blobs_available(%Repository{object_store: %Promisor{}} = repo, commit_sha, path) do
    shas = collect_path_blob_shas(repo, commit_sha, path, MapSet.new(), [])
    missing = Enum.reject(shas, fn sha -> ObjectStore.has?(repo.object_store, sha) end)

    case missing do
      [] -> {:ok, repo}
      _ -> fetch_path_blobs_with_telemetry(repo, path, missing)
    end
  end

  # Batched historical-blob fetch with telemetry. See
  # `fetch_history_with_telemetry/2` for why the span wrapping
  # matters.
  defp fetch_path_blobs_with_telemetry(repo, path, missing) do
    Exgit.Telemetry.span(
      [:exgit, :blame, :auto_fetch],
      %{phase: :path_blobs, path: path, blob_count: length(missing)},
      fn ->
        case batch_fetch(repo, missing) do
          {:ok, new_repo} = ok ->
            {:span, ok, %{cache_bytes: new_repo.object_store.cache_bytes}}

          {:error, reason} = err ->
            {:span, err, %{error: reason}}
        end
      end
    )
  end

  defp ensure_path_blobs_available(repo, _commit_sha, _path), do: {:ok, repo}

  # Walk the first-parent chain, accumulating the blob sha of `path`
  # at each commit. Stops when we hit a commit where the path doesn't
  # exist (the file was introduced later), a commit with no parents,
  # or @max_commits_walked as a safety cap on malformed chains.
  defp collect_path_blob_shas(repo, commit_sha, path, seen, acc)
       when map_size(seen) < @max_commits_walked do
    if MapSet.member?(seen, commit_sha) do
      Enum.uniq(acc)
    else
      seen = MapSet.put(seen, commit_sha)
      step_commit(repo, commit_sha, path, seen, acc)
    end
  end

  defp collect_path_blob_shas(_repo, _commit_sha, _path, _seen, acc) do
    # Safety cap hit — return what we've collected; blame's own walk
    # will surface :unbounded_history when it hits the same boundary.
    Enum.uniq(acc)
  end

  defp step_commit(repo, commit_sha, path, seen, acc) do
    case ObjectStore.get(repo.object_store, commit_sha) do
      {:ok, %Commit{} = commit} ->
        tree_sha = Commit.tree(commit)

        acc =
          case lookup_blob_sha(repo, tree_sha, path) do
            {:ok, blob_sha} -> [blob_sha | acc]
            {:error, _} -> acc
          end

        case Commit.parents(commit) do
          [parent | _] -> collect_path_blob_shas(repo, parent, path, seen, acc)
          [] -> Enum.uniq(acc)
        end

      # Commit not in cache — history wasn't fully fetched. Return
      # what we've collected; blame's walk will terminate when it
      # hits the same boundary.
      _ ->
        Enum.uniq(acc)
    end
  end

  # Pure lookup: given a tree sha and a path, return the blob sha
  # at that path — without going through Promisor on-demand fetch
  # (we assume trees are already cached post-history-prefetch).
  defp lookup_blob_sha(repo, tree_sha, path) do
    segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))
    lookup_path(repo, tree_sha, segments)
  end

  defp lookup_path(_repo, _sha, []), do: {:error, :not_found}

  defp lookup_path(repo, tree_sha, [name]) do
    case ObjectStore.get(repo.object_store, tree_sha) do
      {:ok, %Tree{entries: entries}} ->
        case Enum.find(entries, fn {_, n, _} -> n == name end) do
          {_mode, _, blob_sha} -> {:ok, blob_sha}
          nil -> {:error, :not_found}
        end

      _ ->
        {:error, :tree_not_cached}
    end
  end

  defp lookup_path(repo, tree_sha, [name | rest]) do
    case ObjectStore.get(repo.object_store, tree_sha) do
      {:ok, %Tree{entries: entries}} ->
        case Enum.find(entries, fn {_, n, _} -> n == name end) do
          {"40000", _, sub_sha} -> lookup_path(repo, sub_sha, rest)
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :tree_not_cached}
    end
  end

  # One batched `want sha1 sha2 ... shaN` request. Imports everything
  # the server returns into the Promisor cache.
  defp batch_fetch(%Repository{object_store: %Promisor{} = promisor} = repo, shas) do
    transport = promisor.transport

    with {:ok, pack_bytes, _} <- Exgit.Transport.fetch(transport, shas, haves: []),
         true <- byte_size(pack_bytes) > 0 || {:error, :empty_pack},
         {:ok, parsed} <- Exgit.Pack.Reader.parse(pack_bytes),
         {:ok, new_promisor} <- Promisor.import_objects(promisor, parsed) do
      {:ok, %{repo | object_store: new_promisor}}
    else
      false -> {:error, :empty_pack}
      err -> err
    end
  end

  # --- The walk ---

  # `pending`: %{target_idx => current_commit_line_idx}
  # `attributions`: %{target_idx => commit_sha}
  defp walk(_repo, _sha, _path, pending, attributions, _depth)
       when map_size(pending) == 0 do
    {:ok, attributions}
  end

  defp walk(_repo, _sha, _path, _pending, _attributions, depth)
       when depth >= @max_commits_walked do
    {:error, :unbounded_history}
  end

  defp walk(repo, commit_sha, path, pending, attributions, depth) do
    case get_commit(repo, commit_sha) do
      {:ok, commit} ->
        case Commit.parents(commit) do
          [] ->
            # Root commit: everything still pending originated here.
            {:ok, attribute_all(pending, attributions, commit_sha)}

          [parent_sha | _] ->
            step(repo, commit_sha, parent_sha, path, pending, attributions, depth)
        end

      err ->
        err
    end
  end

  defp step(repo, commit_sha, parent_sha, path, pending, attributions, depth) do
    case read_file_at_commit(repo, parent_sha, path) do
      {:ok, parent_lines} ->
        propagate(repo, commit_sha, parent_sha, path, parent_lines, pending, attributions, depth)

      {:error, :not_found} ->
        # File didn't exist in parent → everything pending was
        # introduced here at commit_sha.
        {:ok, attribute_all(pending, attributions, commit_sha)}

      err ->
        err
    end
  end

  defp propagate(repo, commit_sha, parent_sha, path, parent_lines, pending, attributions, depth) do
    # Read the current commit's lines so we can diff full-to-full.
    case read_file_at_commit(repo, commit_sha, path) do
      {:ok, current_lines} ->
        pairs = LineDiff.matched_pairs(parent_lines, current_lines)

        # Map: current_commit_line_idx → parent_line_idx (for lines
        # that survived from parent to current).
        current_to_parent =
          pairs
          |> Enum.map(fn {a_idx, b_idx} -> {b_idx, a_idx} end)
          |> Map.new()

        {new_pending, new_attributions} =
          Enum.reduce(pending, {%{}, attributions}, fn {target_idx, current_idx},
                                                       {np, attrs} ->
            case Map.fetch(current_to_parent, current_idx) do
              {:ok, parent_idx} ->
                # Line survives → update pending to parent's idx.
                {Map.put(np, target_idx, parent_idx), attrs}

              :error ->
                # Line is new at commit_sha → attribute.
                {np, Map.put(attrs, target_idx, commit_sha)}
            end
          end)

        walk(repo, parent_sha, path, new_pending, new_attributions, depth + 1)

      err ->
        err
    end
  end

  defp attribute_all(pending, attributions, commit_sha) do
    Enum.reduce(pending, attributions, fn {target_idx, _}, acc ->
      Map.put(acc, target_idx, commit_sha)
    end)
  end

  # --- Commit and file helpers ---

  defp resolve_commit(_repo, reference)
       when is_binary(reference) and byte_size(reference) == 20 do
    {:ok, reference}
  end

  defp resolve_commit(repo, reference) when is_binary(reference) do
    case RefStore.read(repo.ref_store, reference) do
      {:ok, sha} when is_binary(sha) and byte_size(sha) == 20 ->
        {:ok, sha}

      {:ok, {:symbolic, target}} ->
        resolve_commit(repo, target)

      _ ->
        {:error, :not_found}
    end
  end

  defp get_commit(repo, sha) do
    case ObjectStore.get(repo.object_store, sha) do
      {:ok, %Commit{} = c} -> {:ok, c}
      {:ok, _} -> {:error, :not_a_commit}
      err -> err
    end
  end

  defp read_file_at_commit(repo, commit_sha, path) do
    with {:ok, commit} <- get_commit(repo, commit_sha),
         tree_sha = Commit.tree(commit),
         {:ok, blob_data} <- read_blob_at_tree(repo, tree_sha, path) do
      {:ok, split_lines(blob_data)}
    end
  end

  defp read_blob_at_tree(repo, tree_sha, path) do
    segments = path |> String.split("/") |> Enum.reject(&(&1 == ""))
    walk_tree(repo, tree_sha, segments)
  end

  defp walk_tree(_repo, _sha, []), do: {:error, :not_a_blob}

  defp walk_tree(repo, tree_sha, [name]) do
    case ObjectStore.get(repo.object_store, tree_sha) do
      {:ok, %Tree{entries: entries}} ->
        case Enum.find(entries, fn {_mode, n, _} -> n == name end) do
          {_mode, ^name, blob_sha} ->
            case ObjectStore.get(repo.object_store, blob_sha) do
              {:ok, %Blob{data: data}} -> {:ok, data}
              _ -> {:error, :not_a_blob}
            end

          nil ->
            {:error, :not_found}
        end

      err ->
        err
    end
  end

  defp walk_tree(repo, tree_sha, [name | rest]) do
    case ObjectStore.get(repo.object_store, tree_sha) do
      {:ok, %Tree{entries: entries}} ->
        case Enum.find(entries, fn {_mode, n, _} -> n == name end) do
          {"40000", ^name, sub_sha} -> walk_tree(repo, sub_sha, rest)
          {_mode, ^name, _} -> {:error, :not_a_blob}
          nil -> {:error, :not_found}
        end

      err ->
        err
    end
  end

  # Split blob bytes into lines matching grep's convention (no
  # phantom trailing empty line for a file ending in \n).
  defp split_lines(""), do: []

  defp split_lines(data) do
    parts = String.split(data, "\n")

    if String.ends_with?(data, "\n"),
      do: Enum.drop(parts, -1),
      else: parts
  end

  # --- Entry construction ---

  defp build_entries(repo, target_lines, attrib_map) do
    shas = attrib_map |> Map.values() |> Enum.uniq()
    commits_by_sha = preload_commits(repo, shas)

    entries =
      for {line, i} <- Enum.with_index(target_lines) do
        sha = Map.get(attrib_map, i)
        c = Map.get(commits_by_sha, sha)
        meta = commit_metadata(c)

        %{
          line_number: i + 1,
          line: line,
          commit_sha: sha,
          author_name: meta.author_name,
          author_email: meta.author_email,
          author_time: meta.author_time,
          summary: meta.summary
        }
      end

    {:ok, entries}
  end

  defp preload_commits(repo, shas) do
    Enum.reduce(shas, %{}, fn sha, acc ->
      case get_commit(repo, sha) do
        {:ok, c} -> Map.put(acc, sha, c)
        _ -> acc
      end
    end)
  end

  defp commit_metadata(nil) do
    %{author_name: "", author_email: "", author_time: 0, summary: ""}
  end

  defp commit_metadata(%Commit{message: message} = c) do
    {name, email, time} = parse_author(Commit.author(c))
    summary = message |> String.split("\n", parts: 2) |> hd()

    %{author_name: name, author_email: email, author_time: time, summary: summary}
  end

  defp parse_author(line) when is_binary(line) do
    case Regex.run(~r/^(.+?)\s+<([^>]*)>\s+(\d+)\s+[+-]\d{4}/, line) do
      [_, name, email, ts] -> {name, email, String.to_integer(ts)}
      _ -> {"", "", 0}
    end
  end
end
