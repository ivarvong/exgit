defmodule Exgit.Workspace do
  @moduledoc """
  An agent-loop working tree on top of a git ref.

  A workspace pairs `(repository, base_ref, head_tree)`:

    * `:base_ref` — the starting point ("HEAD", a branch, a commit SHA).
    * `:head_tree` — the current working tree's SHA. `nil` when the
      workspace is pristine; reads in that state pass through to
      `base_ref`. Set to a 20-byte tree SHA after the first write.

  Every state of the workspace is a real git tree object. Snapshots
  are 20-byte SHAs you can persist and replay; commits are an O(1)
  hash-and-store on top of the head tree; branching the workspace
  for parallel exploration is `ws_b = ws_a` — the struct is a value,
  no copy needed.

  ## Lifecycle

      ws = Exgit.Workspace.open(repo, "main")
      {:ok, ws} = Exgit.Workspace.write(ws, "lib/foo.ex", new_source)
      {:ok, ws} = Exgit.Workspace.rm(ws, "lib/old.ex")

      {:ok, content, ws} = Exgit.Workspace.read(ws, "lib/foo.ex")
      {:ok, [{:modified, "lib/foo.ex"}, {:deleted, "lib/old.ex"}], ws}
        = Exgit.Workspace.diff(ws)

      {:ok, commit_sha, ws} =
        Exgit.Workspace.commit(ws,
          message: "agent: refactor",
          author: %{name: "agent", email: "agent@example.com"},
          update_ref: "refs/heads/agent-turn-1")

  ## Snapshot / restore

      saved = Exgit.Workspace.snapshot(ws)   # :pristine | <<20-byte sha>>
      ws = Exgit.Workspace.restore(ws, saved)

  Snapshots are opaque values you can stash anywhere — a database,
  another conversation, a Linear comment. To replay an agent's run
  end-to-end, restore from the saved value.

  ## Branching

  Pass the same workspace to two parallel computations; each gets its
  own threaded state.

      ws_a = ws
      ws_b = ws

      {:ok, ws_a} = Exgit.Workspace.write(ws_a, "lib/x.ex", "...")
      {:ok, ws_b} = Exgit.Workspace.write(ws_b, "lib/x.ex", "different")

  `ws_a` and `ws_b` now diverge. The underlying object store is shared
  (each write puts new blobs/trees) but neither workspace's `head_tree`
  references the other's writes.

  ## VFS integration

  When `:vfs` is loaded, `Exgit.Workspace` implements `VFS.Mountable`
  and can be mounted into a `%VFS{}` mount table. See
  `Exgit.Workspace.VFS`.
  """

  alias Exgit.Diff
  alias Exgit.FS
  alias Exgit.Object.{Blob, Commit}
  alias Exgit.{ObjectStore, RefStore, Repository}

  @enforce_keys [:repo, :base_ref]
  defstruct [:repo, :base_ref, :head_tree]

  @type t :: %__MODULE__{
          repo: Repository.t(),
          base_ref: String.t() | binary(),
          head_tree: binary() | nil
        }

  @typedoc """
  Identity for `commit/2`. Either a pre-formatted git identity string
  (`"Name <email> ts +tz"`) used verbatim, or a `%{name:, email:}` map
  which is rendered with the current timestamp at UTC.
  """
  @type identity :: String.t() | %{required(:name) => String.t(), required(:email) => String.t()}

  @typedoc """
  An entry returned by `diff/1`. Path is relative to the repo root.
  """
  @type change :: {:added | :modified | :deleted, String.t()}

  @typedoc """
  Opaque snapshot value. Either the sentinel `:pristine` or a 20-byte
  tree SHA.
  """
  @type snapshot :: :pristine | binary()

  # ──────────────────────────────────────────────────────────────────
  # Construction
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Open a workspace over `repo` rooted at `ref` (default `"HEAD"`).

  The workspace starts pristine — `head_tree` is `nil`, reads go
  straight to `ref`.
  """
  @spec open(Repository.t(), String.t()) :: t()
  def open(%Repository{} = repo, ref \\ "HEAD") when is_binary(ref) do
    %__MODULE__{repo: repo, base_ref: ref, head_tree: nil}
  end

  # ──────────────────────────────────────────────────────────────────
  # Reads
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Read the file at `path`. Returns the blob bytes plus the threaded
  workspace.
  """
  @spec read(t(), String.t()) :: {:ok, binary(), t()} | {:error, term()}
  def read(%__MODULE__{} = ws, path) do
    case FS.read_path(ws.repo, effective_ref(ws), path) do
      {:ok, {_mode, %Blob{data: data}}, repo} ->
        {:ok, data, %{ws | repo: repo}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  List names of entries directly under `path`. Sorted lexicographically.
  """
  @spec ls(t(), String.t()) :: {:ok, [String.t()], t()} | {:error, term()}
  def ls(%__MODULE__{} = ws, path) do
    case FS.ls(ws.repo, effective_ref(ws), path) do
      {:ok, entries, repo} ->
        names = entries |> Enum.map(fn {_m, n, _s} -> n end) |> Enum.sort()
        {:ok, names, %{ws | repo: repo}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Stat the entry at `path`. Returns `%{type: :blob | :tree, mode:, size:}`.
  """
  @spec stat(t(), String.t()) :: {:ok, FS.stat(), t()} | {:error, term()}
  def stat(%__MODULE__{} = ws, path) do
    case FS.stat(ws.repo, effective_ref(ws), path) do
      {:ok, stat, repo} -> {:ok, stat, %{ws | repo: repo}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Whether `path` exists in the current working state.
  """
  @spec exists?(t(), String.t()) :: {boolean(), t()}
  def exists?(%__MODULE__{} = ws, path) do
    {FS.exists?(ws.repo, effective_ref(ws), path), ws}
  end

  @doc """
  Stream every blob path under the workspace's working state. Like
  `Exgit.FS.walk/2`, requires the underlying repo to be `:eager` —
  call `materialize/1` first on lazy partial-clone repos.
  """
  @spec walk(t()) :: Enumerable.t()
  def walk(%__MODULE__{} = ws) do
    FS.walk(ws.repo, effective_ref(ws))
  end

  # ──────────────────────────────────────────────────────────────────
  # Writes
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Write `content` to `path`. Creates intermediate directories
  implicitly. Refuses to overwrite a directory.
  """
  @spec write(t(), String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def write(%__MODULE__{} = ws, path, content) when is_binary(content) do
    with :ok <- guard_not_directory(ws, path),
         {:ok, new_tree, repo} <- FS.write_path(ws.repo, effective_ref(ws), path, content) do
      {:ok, %{ws | repo: repo, head_tree: new_tree}}
    end
  end

  @doc """
  Remove the entry at `path`.

  Options:

    * `:recursive` — when `true`, removing a directory removes its
      contents. Default `false`; without it, directory removal returns
      `{:error, :eisdir}`.
  """
  @spec rm(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def rm(%__MODULE__{} = ws, path, opts \\ []) do
    case FS.rm_path(ws.repo, effective_ref(ws), path, opts) do
      {:ok, new_tree, repo} ->
        {:ok, %{ws | repo: repo, head_tree: new_tree}}

      {:error, _} = err ->
        err
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Snapshot / restore / fork
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Capture the workspace's working state as an opaque snapshot value.

  Returns `:pristine` for a workspace with no writes, otherwise the
  20-byte tree SHA. Persistable, transferable, and replayable via
  `restore/2`.
  """
  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{head_tree: nil}), do: :pristine
  def snapshot(%__MODULE__{head_tree: tree}), do: tree

  @doc """
  Replace the workspace's head tree with a previously-captured snapshot.

  The snapshot's referenced objects must already be in the underlying
  repo's object store — this is the case when the snapshot was produced
  by a workspace sharing the same store.
  """
  @spec restore(t(), snapshot()) :: t()
  def restore(%__MODULE__{} = ws, :pristine), do: %{ws | head_tree: nil}

  def restore(%__MODULE__{} = ws, tree) when is_binary(tree) and byte_size(tree) == 20 do
    %{ws | head_tree: tree}
  end

  # ──────────────────────────────────────────────────────────────────
  # Move / revert
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Move (rename) `from` to `to`. Preserves the file mode.

  Refuses to move directories in v1 — `from` must be a file. Refuses
  to overwrite an existing directory at `to`.
  """
  @spec move(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def move(%__MODULE__{} = ws, from, to) when is_binary(from) and is_binary(to) do
    case FS.read_path(ws.repo, effective_ref(ws), from) do
      {:ok, {mode, %Blob{data: data}}, repo} ->
        ws = %{ws | repo: repo}

        with :ok <- guard_not_directory(ws, to),
             {:ok, ws} <- do_write(ws, to, data, mode: mode) do
          rm(ws, from)
        end

      {:error, :not_a_blob} ->
        {:error, :cannot_move_directory}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Revert edits to `path` — restore it to its content in `base_ref`.

  Three cases:

    * Path exists in base and head differs → write base's content back.
    * Path doesn't exist in base, exists in head (agent added it) → rm
      from head.
    * Path doesn't exist in either → no-op.

  A pristine workspace is a no-op (nothing to revert).
  """
  @spec revert(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def revert(%__MODULE__{head_tree: nil} = ws, _path), do: {:ok, ws}

  def revert(%__MODULE__{} = ws, path) do
    case FS.read_path(ws.repo, ws.base_ref, path) do
      {:ok, {mode, %Blob{data: data}}, repo} ->
        ws = %{ws | repo: repo}
        do_write(ws, path, data, mode: mode)

      {:error, :not_found} ->
        case FS.rm_path(ws.repo, effective_ref(ws), path) do
          {:ok, new_tree, repo} ->
            {:ok, %{ws | repo: repo, head_tree: new_tree}}

          {:error, :not_found} ->
            {:ok, ws}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_write(%__MODULE__{} = ws, path, content, opts) do
    case FS.write_path(ws.repo, effective_ref(ws), path, content, opts) do
      {:ok, new_tree, repo} -> {:ok, %{ws | repo: repo, head_tree: new_tree}}
      {:error, _} = err -> err
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Merge
  # ──────────────────────────────────────────────────────────────────

  @typedoc """
  A conflict reported by `merge/3`.
  """
  @type merge_conflict :: FS.merge_conflict()

  @doc """
  Merge another tree-shaped state into this workspace.

  `source` accepts:

    * `:pristine` — no-op (source has no changes).
    * another `%Exgit.Workspace{}` — typical agent-loop pattern.
      Objects reachable from the source's working tree are imported
      into this workspace's repo before merging, so two workspaces
      forked from a common ancestor can re-converge even though
      each has accumulated its own object-store state.
    * a 20-byte tree or commit SHA — assumed to be resolvable in
      this workspace's repo (no auto-import).
    * a ref name like `"refs/heads/feature"` — resolves to its tree
      in this workspace's repo.

  The merge is **path-level, three-way**: the merge base is the
  workspace's `base_ref`'s tree by default. Override with the
  `:base` option (snapshot/ref/sha; must be resolvable in this
  workspace's repo).

  Strategies (`:strategy` opt):

    * `:abort` (default) — if any conflict, return
      `{:conflict, conflicts, ws}` with the workspace's `head_tree`
      unchanged. Repo cache may have grown from diff resolution and
      object import; that growth threads back. Agents can re-read
      both versions and decide.
    * `:ours` / `:theirs` — auto-resolve conflicts with the named
      side; return `{:ok, ws}` plus the conflict list reported but
      already resolved.

  Non-conflicting changes from `source` apply only when there are
  no conflicts at all under `:abort` (atomic).
  """
  @spec merge(t(), :pristine | t() | String.t() | binary(), keyword()) ::
          {:ok, t()}
          | {:conflict, [merge_conflict()], t()}
          | {:error, term()}
  def merge(ws, source, opts \\ [])

  def merge(%__MODULE__{} = ws, :pristine, _opts), do: {:ok, ws}

  def merge(%__MODULE__{} = target, %__MODULE__{} = source, opts) do
    source_tree = source.head_tree || nil

    case source_tree do
      nil ->
        # source is pristine — its working tree IS its base_ref.
        # Resolve in the source's repo, then proceed.
        with {:ok, src_tree, _} <- resolve_ref_to_tree(source.repo, source.base_ref),
             {:ok, target} <- import_objects_from(target, source, src_tree) do
          do_merge(target, src_tree, opts)
        end

      tree_sha ->
        with {:ok, target} <- import_objects_from(target, source, tree_sha) do
          do_merge(target, tree_sha, opts)
        end
    end
  end

  def merge(%__MODULE__{} = ws, source, opts) when is_binary(source) do
    case resolve_to_tree(ws.repo, source) do
      {:ok, source_tree, repo} -> do_merge(%{ws | repo: repo}, source_tree, opts)
      {:error, _} = err -> err
    end
  end

  defp do_merge(%__MODULE__{} = ws, source_tree, opts) do
    strategy = Keyword.get(opts, :strategy, :abort)

    with {:ok, base_tree, repo} <- resolve_merge_base(ws.repo, ws, opts),
         ours_tree = ws.head_tree || base_tree,
         {:ok, merged, conflicts, repo} <-
           FS.merge_trees(repo, base_tree, ours_tree, source_tree, strategy: strategy) do
      ws = %{ws | repo: repo}

      cond do
        conflicts == [] ->
          {:ok, advance_head(ws, merged, base_tree)}

        strategy == :abort ->
          {:conflict, conflicts, ws}

        true ->
          {:ok, advance_head(ws, merged, base_tree)}
      end
    end
  end

  # Copy every object reachable from `source_tree` from `source.repo`
  # into `target.repo`. For Memory stores this is cheap; for Promisor
  # stores it walks through the resident cache (any non-resident
  # objects must already be fetched on the source side, or the merge
  # will fail when fetching them through the target's transport).
  defp import_objects_from(target, source, source_tree) do
    case copy_object(target.repo, source.repo, source_tree) do
      {:ok, repo} -> {:ok, %{target | repo: repo}}
      {:error, _} = err -> err
    end
  end

  defp copy_object(target_repo, source_repo, sha) do
    if ObjectStore.has?(target_repo.object_store, sha) do
      {:ok, target_repo}
    else
      case ObjectStore.get(source_repo.object_store, sha) do
        {:ok, %Exgit.Object.Tree{entries: entries} = tree} ->
          {:ok, _new_sha, store} = ObjectStore.put(target_repo.object_store, tree)
          target_repo = %{target_repo | object_store: store}

          # Recurse into entries: blobs and subtrees both need copying.
          Enum.reduce_while(entries, {:ok, target_repo}, fn {_mode, _name, entry_sha},
                                                            {:ok, repo} ->
            case copy_object(repo, source_repo, entry_sha) do
              {:ok, repo} -> {:cont, {:ok, repo}}
              {:error, _} = err -> {:halt, err}
            end
          end)

        {:ok, %Exgit.Object.Blob{} = blob} ->
          {:ok, _new_sha, store} = ObjectStore.put(target_repo.object_store, blob)
          {:ok, %{target_repo | object_store: store}}

        {:ok, other} ->
          # Commits / tags from a working-tree merge shouldn't surface,
          # but if they do, copy through.
          {:ok, _new_sha, store} = ObjectStore.put(target_repo.object_store, other)
          {:ok, %{target_repo | object_store: store}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp advance_head(ws, merged_tree, base_tree) do
    if merged_tree == base_tree,
      do: %{ws | head_tree: nil},
      else: %{ws | head_tree: merged_tree}
  end

  defp resolve_merge_base(repo, ws, opts) do
    case Keyword.fetch(opts, :base) do
      {:ok, :pristine} -> resolve_ref_to_tree(repo, ws.base_ref)
      {:ok, b} when is_binary(b) -> resolve_to_tree(repo, b)
      :error -> resolve_ref_to_tree(repo, ws.base_ref)
    end
  end

  defp resolve_to_tree(repo, ref_or_sha) when is_binary(ref_or_sha) do
    if byte_size(ref_or_sha) == 20 do
      resolve_sha_to_tree(repo, ref_or_sha)
    else
      resolve_ref_to_tree(repo, ref_or_sha)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Diff
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Compare the workspace's working state against `base_ref`, returning
  a list of `{:added | :modified | :deleted, path}` entries.

  A pristine workspace returns `{:ok, [], ws}` immediately. For richer
  output (content of changed paths) or comparison against a different
  target, use `diff/2`.
  """
  @spec diff(t()) :: {:ok, [change()], t()} | {:error, term()}
  def diff(%__MODULE__{} = ws), do: diff(ws, [])

  @doc """
  Like `diff/1`, with options:

    * `:against` — compare against this state instead of `base_ref`.
      Accepts `:pristine` (alias for `base_ref`), a 20-byte tree/commit
      SHA, or a ref name. Useful for `Workspace.diff(ws, against:
      saved_snapshot)` to see what's changed since a checkpoint.

    * `:content` (default `false`) — when `true`, return rich entries
      `%{op:, path:, before:, after:}` where `:before` and `:after`
      are the blob bytes (`nil` for added/deleted respectively, and
      `nil` for non-blob operands like type changes).
  """
  @spec diff(t(), keyword()) ::
          {:ok, [change()] | [content_change()], t()} | {:error, term()}
  def diff(%__MODULE__{head_tree: nil} = ws, opts) do
    if Keyword.has_key?(opts, :against),
      do: do_diff(ws, opts),
      else: {:ok, [], ws}
  end

  def diff(%__MODULE__{} = ws, opts), do: do_diff(ws, opts)

  defp do_diff(%__MODULE__{} = ws, opts) do
    against = Keyword.get(opts, :against, :base_ref)
    content? = Keyword.get(opts, :content, false)

    with {:ok, against_tree, repo} <- resolve_diff_target(ws.repo, against, ws.base_ref),
         {:ok, current_tree, repo} <- resolve_current_tree(repo, ws),
         {:ok, changes} <- Diff.trees(repo, against_tree, current_tree) do
      ws = %{ws | repo: repo}

      if content?,
        do: enrich_with_content(changes, ws),
        else: {:ok, simplify_changes(changes), ws}
    end
  end

  defp resolve_diff_target(repo, :base_ref, base_ref), do: resolve_ref_to_tree(repo, base_ref)
  defp resolve_diff_target(repo, :pristine, base_ref), do: resolve_ref_to_tree(repo, base_ref)

  defp resolve_diff_target(repo, target, _base_ref) when is_binary(target),
    do: resolve_to_tree(repo, target)

  defp resolve_current_tree(repo, %__MODULE__{head_tree: nil, base_ref: ref}),
    do: resolve_ref_to_tree(repo, ref)

  defp resolve_current_tree(repo, %__MODULE__{head_tree: tree}), do: {:ok, tree, repo}

  defp enrich_with_content(changes, ws) do
    enriched = Enum.map(changes, &enrich_change(&1, ws))
    {:ok, enriched, ws}
  end

  defp enrich_change(%{op: op, path: path} = c, ws) when op in [:added, :removed, :modified] do
    {before_sha, after_sha} =
      case op do
        :added -> {nil, c.new_sha}
        :removed -> {c.old_sha, nil}
        :modified -> {c.old_sha, c.new_sha}
      end

    %{
      op: simplify_op(op),
      path: path,
      before: fetch_blob_bytes(ws, before_sha),
      after: fetch_blob_bytes(ws, after_sha)
    }
  end

  # Mode/type/submodule changes — content semantics ambiguous.
  # Surface as :modified with nil content.
  defp enrich_change(%{path: path}, _ws),
    do: %{op: :modified, path: path, before: nil, after: nil}

  defp fetch_blob_bytes(_ws, nil), do: nil

  defp fetch_blob_bytes(ws, sha) when is_binary(sha) do
    case ObjectStore.get(ws.repo.object_store, sha) do
      {:ok, %Blob{data: data}} -> data
      # Non-blob (tree/etc) — content not meaningful at file level.
      _ -> nil
    end
  end

  defp simplify_op(:removed), do: :deleted
  defp simplify_op(other), do: other

  defp simplify_changes(changes) do
    Enum.map(changes, fn
      %{op: :added, path: p} -> {:added, p}
      %{op: :removed, path: p} -> {:deleted, p}
      %{op: :modified, path: p} -> {:modified, p}
      %{op: :mode_changed, path: p} -> {:modified, p}
      %{op: :type_changed, path: p} -> {:modified, p}
      %{op: :submodule_change, path: p} -> {:modified, p}
    end)
  end

  @typedoc """
  Rich change entry returned by `diff/2` with `content: true`.
  `:before` is `nil` for added paths; `:after` is `nil` for deleted
  paths; both are `nil` for non-blob operations.
  """
  @type content_change :: %{
          op: :added | :modified | :deleted,
          path: String.t(),
          before: binary() | nil,
          after: binary() | nil
        }

  # ──────────────────────────────────────────────────────────────────
  # Walk convenience
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Materialize the workspace and return a walk stream in one call.

  `Workspace.walk/1` requires the underlying repo to be `:eager` —
  on a lazy partial-clone repo it raises. This helper materializes
  first (one network round-trip prefetching reachable trees and
  blobs) and then returns the walk stream, threading the
  materialized workspace back so cache growth is captured.

      {:ok, stream, ws} = Exgit.Workspace.materialized_walk(ws)
      stream |> Stream.take(10) |> Enum.to_list()

  Idempotent on already-eager repos.
  """
  @spec materialized_walk(t()) :: {:ok, Enumerable.t(), t()} | {:error, term()}
  def materialized_walk(%__MODULE__{} = ws) do
    case materialize(ws) do
      {:ok, ws} -> {:ok, walk(ws), ws}
      {:error, _} = err -> err
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Commit
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Materialize the working tree as a commit object.

  Required options:

    * `:message` — commit message (a binary, with or without trailing newline).
    * `:author` — `t:identity/0`.

  Optional:

    * `:committer` — defaults to `:author`.
    * `:update_ref` — `false` (default) leaves refs untouched; the
      caller takes the returned commit SHA. A binary like
      `"refs/heads/agent-turn-1"` writes that ref to point at the new
      commit and tracks it as the workspace's new `base_ref`. The ref
      may already exist; it is overwritten.

  After commit, `head_tree` is cleared and `base_ref` advances to
  identify where the new commit lives:

    * `update_ref: false` → `base_ref` becomes the commit SHA (binary).
    * `update_ref: "refs/heads/foo"` → `base_ref` becomes that string.

  Returns `{:error, :nothing_to_commit}` if the workspace is pristine.
  """
  @spec commit(t(), keyword()) :: {:ok, binary(), t()} | {:error, term()}
  def commit(%__MODULE__{head_tree: nil}, _opts), do: {:error, :nothing_to_commit}

  def commit(%__MODULE__{} = ws, opts) do
    message = Keyword.fetch!(opts, :message)
    author = format_identity(Keyword.fetch!(opts, :author))
    committer = opts |> Keyword.get(:committer, author) |> format_identity()
    update_ref = Keyword.get(opts, :update_ref, false)

    with {:ok, parents, repo} <- parent_commit_shas(ws.repo, ws.base_ref) do
      ws = %{ws | repo: repo}

      commit =
        Commit.new(
          tree: ws.head_tree,
          parents: parents,
          author: author,
          committer: committer,
          message: ensure_trailing_newline(message)
        )

      {:ok, commit_sha, store} = ObjectStore.put(ws.repo.object_store, commit)
      repo = %{ws.repo | object_store: store}

      case advance_ref(repo, update_ref, commit_sha) do
        {:ok, repo, new_base_ref} ->
          {:ok, commit_sha, %{ws | repo: repo, head_tree: nil, base_ref: new_base_ref}}

        {:error, _} = err ->
          err
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Materialize / checkout
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Convert a lazy partial-clone repo to eager mode by prefetching every
  object reachable from the workspace's effective ref. After this,
  streaming ops (`walk/1`, `Exgit.FS.grep/4`) work without per-blob
  network round-trips.

  No-op for already-eager repos.
  """
  @spec materialize(t()) :: {:ok, t()} | {:error, term()}
  def materialize(%__MODULE__{} = ws) do
    case Repository.materialize(ws.repo, effective_ref(ws)) do
      {:ok, repo} -> {:ok, %{ws | repo: repo}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Switch the workspace's `base_ref`. Discards any uncommitted writes
  (`head_tree` is reset to `nil`).
  """
  @spec checkout(t(), String.t()) :: {:ok, t()}
  def checkout(%__MODULE__{} = ws, ref) when is_binary(ref) do
    {:ok, %{ws | base_ref: ref, head_tree: nil}}
  end

  # ──────────────────────────────────────────────────────────────────
  # Internals
  # ──────────────────────────────────────────────────────────────────

  defp effective_ref(%__MODULE__{head_tree: nil, base_ref: ref}), do: ref
  defp effective_ref(%__MODULE__{head_tree: tree}), do: tree

  defp guard_not_directory(ws, path) do
    case FS.stat(ws.repo, effective_ref(ws), path) do
      {:ok, %{type: :tree}, _repo} -> {:error, :eisdir}
      _ -> :ok
    end
  end

  # Resolve any ref/sha down to a tree-sha. `Exgit.FS.resolve_tree/2`
  # is private; this mirrors its external contract for the cases the
  # workspace produces (named refs and 20-byte commit/tree SHAs).
  defp resolve_ref_to_tree(%Repository{} = repo, ref) when is_binary(ref) do
    if byte_size(ref) == 20 do
      resolve_sha_to_tree(repo, ref)
    else
      case RefStore.resolve(repo.ref_store, ref) do
        {:ok, sha} -> resolve_sha_to_tree(repo, sha)
        {:error, _} = err -> err
      end
    end
  end

  defp resolve_sha_to_tree(repo, sha) do
    case ObjectStore.get(repo.object_store, sha) do
      {:ok, %Commit{} = c} -> {:ok, Commit.tree(c), repo}
      {:ok, %Exgit.Object.Tree{}} -> {:ok, sha, repo}
      {:ok, _} -> {:error, :not_a_commit_or_tree}
      {:error, _} = err -> err
    end
  end

  # Resolve `base_ref` to the parent-commits list for a new commit.
  # Returns `{:ok, [parent_sha], repo}` when the ref points at a real
  # commit, `{:ok, [], repo}` when there's no commit yet (initial
  # commit case — base_ref is a bare tree-sha or doesn't resolve).
  defp parent_commit_shas(%Repository{} = repo, ref) when is_binary(ref) do
    cond do
      byte_size(ref) == 20 ->
        resolve_parent_sha(repo, ref)

      true ->
        case RefStore.resolve(repo.ref_store, ref) do
          {:ok, sha} -> resolve_parent_sha(repo, sha)
          {:error, :not_found} -> {:ok, [], repo}
          {:error, _} = err -> err
        end
    end
  end

  defp resolve_parent_sha(repo, sha) do
    case ObjectStore.get(repo.object_store, sha) do
      {:ok, %Commit{}} -> {:ok, [sha], repo}
      {:ok, _} -> {:ok, [], repo}
      {:error, _} -> {:ok, [], repo}
    end
  end

  defp advance_ref(repo, false, commit_sha), do: {:ok, repo, commit_sha}

  defp advance_ref(repo, ref_name, commit_sha) when is_binary(ref_name) do
    case RefStore.write(repo.ref_store, ref_name, commit_sha, []) do
      {:ok, ref_store} -> {:ok, %{repo | ref_store: ref_store}, ref_name}
      {:error, _} = err -> err
    end
  end

  defp format_identity(s) when is_binary(s), do: s

  defp format_identity(%{name: name, email: email})
       when is_binary(name) and is_binary(email) do
    ts = System.os_time(:second)
    "#{name} <#{email}> #{ts} +0000"
  end

  defp ensure_trailing_newline(""), do: "\n"

  defp ensure_trailing_newline(msg) do
    if String.ends_with?(msg, "\n"), do: msg, else: msg <> "\n"
  end
end
