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
  """
  @spec read_path(Repository.t(), ref(), path()) ::
          {:ok, {String.t(), Blob.t()}, Repository.t()}
          | {:error, :not_found | :not_a_blob | term()}
  def read_path(%Repository{} = repo, reference, path) do
    Exgit.Telemetry.span(
      [:exgit, :fs, :read_path],
      %{reference: reference, path: path},
      fn ->
        with {:ok, tree_sha, repo} <- resolve_tree(repo, reference),
             {:ok, {mode, sha}, repo} <- walk_path(repo, tree_sha, normalize_path(path)),
             {:ok, obj, repo} <- fetch_object(repo, sha) do
          case obj do
            %Blob{} = b -> {:ok, {mode, b}, repo}
            _ -> {:error, :not_a_blob}
          end
        end
      end
    )
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

    Stream.resource(
      fn ->
        # Resolve the tree eagerly (may grow cache, but we discard the
        # updated repo — this is a stream, callers don't expect state).
        case resolve_tree(repo, reference) do
          {:ok, sha, _repo} -> [{"", sha}]
          _ -> []
        end
      end,
      fn
        [] ->
          {:halt, :done}

        [{prefix, tree_sha} | rest] ->
          {emits, new_stack} = expand_pure(repo, prefix, tree_sha, rest)
          :counters.add(count, 1, length(emits))
          {emits, new_stack}
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
          required(:match) => String.t()
        }

  @doc """
  Stream grep over the blobs reachable from `reference`. Streaming; does
  not grow the cache.
  """
  @spec grep(Repository.t(), ref(), String.t() | Regex.t(), keyword()) :: Enumerable.t()
  def grep(%Repository{} = repo, reference, pattern, opts \\ []) do
    :ok = require_eager!(repo, :grep)
    regex = compile_grep_pattern(pattern, opts)
    path_glob = Keyword.get(opts, :path, "**")
    path_regex = compile_glob(path_glob)
    max_count = Keyword.get(opts, :max_count)
    include_binary = Keyword.get(opts, :include_binary, false)

    start_time = System.monotonic_time()
    match_counter = :counters.new(1, [])
    file_counter = :counters.new(1, [])
    bytes_counter = :counters.new(1, [])

    metadata = %{
      reference: reference,
      pattern: pattern_repr(pattern),
      path_glob: path_glob
    }

    :telemetry.execute(
      [:exgit, :fs, :grep, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      metadata
    )

    stream =
      walk(repo, reference)
      |> Stream.filter(fn {path, _sha} -> Regex.match?(path_regex, path) end)
      |> Stream.flat_map(fn {path, sha} ->
        case ObjectStore.get(repo.object_store, sha) do
          {:ok, %Blob{data: data}} ->
            :counters.add(file_counter, 1, 1)
            :counters.add(bytes_counter, 1, byte_size(data))

            if include_binary or not binary_content?(data) do
              matches = matches_in(path, data, regex)
              :counters.add(match_counter, 1, length(matches))
              matches
            else
              []
            end

          _ ->
            []
        end
      end)

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

  defp matches_in(path, data, regex) do
    data
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      case Regex.run(regex, line, capture: :first) do
        nil -> []
        [matched] -> [%{path: path, line_number: lineno, line: line, match: matched}]
      end
    end)
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
