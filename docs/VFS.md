# VFS integration

`:vfs` ([github.com/ivarvong/vfs](https://github.com/ivarvong/vfs)) is
the protocol-based virtual-filesystem layer that sits *above* exgit.
Agents in production rarely consume git in isolation — they compose a
read-write working tree (git), a scratch (in-memory), and a durable
per-tenant store (postgres/S3) under one tree. `:vfs` provides the
mount table and the `VFS.Mountable` protocol; exgit ships
`Exgit.Workspace`, a working-tree-on-top-of-a-ref, as a backend.

## Concept

The integration is a wrapper struct, `Exgit.Workspace`, that pairs
`(repository, base_ref, head_tree)`:

  * `:base_ref` — the starting point ("HEAD", a branch, a commit SHA).
  * `:head_tree` — the working tree's SHA (20 bytes), or `nil` when
    the workspace is pristine. Reads use `head_tree || base_ref`.

Every state of the workspace is a real git tree object. That gives
us:

  * **Snapshot is free.** Just save the head_tree binary.
  * **Branching is free.** `ws_b = ws_a` — both diverge independently.
  * **Commit is instantaneous.** The work is already done; we have
    the tree.
  * **Diff is structured.** `Exgit.Diff.trees/4` against `base_ref`.

Trade-off: empty directories don't exist (git doesn't store them) and
writes cost O(depth × log fanout) rather than O(1). For typical agent
workloads (depth <10, <100 entries per dir) writes are ~100µs each
in-memory.

## Dependency direction

`:exgit` takes `:vfs` as an **optional** dep. `:vfs` never depends on
`:exgit`.

```elixir
# mix.exs in :exgit (already wired)
{:vfs, github: "ivarvong/vfs", ref: "...", optional: true, only: [:dev, :test]}
```

The `Exgit.Workspace.VFS` module wraps the entire defimpl in
`Code.ensure_loaded?(VFS.Mountable)`. Production builds without
`:vfs` resolved drop it cleanly; `Exgit.Workspace` itself is fully
usable as a standalone API.

## Capabilities

```elixir
MapSet.new([:read, :write, :lazy])
```

Not `:mkdir` — git trees can't represent empty directories, so a
faithful `mkdir/3` has no honest semantics. `write_file/4` implicitly
creates parent directories (vfs explicitly supports this for
flat-keyed backends).

## State threading

`VFS.Mountable` requires every op to return the (possibly updated)
backend impl as the last element of its success tuple. The workspace
threads two pieces of state on each call:

  1. `repo.object_store` — grows on lazy partial-clone fetches.
  2. `head_tree` — advances on every write.

The conformance suite's "state threading" tests exercise this
explicitly: a write returns a workspace whose subsequent reads
reflect the write.

## Path translation

vfs paths are absolute with a leading `/`. `Exgit.FS` paths are
slash-tolerant but treat `""` as the root tree. The defimpl strips
the leading slash before calling FS:

```elixir
defp strip_leading("/"),         do: ""
defp strip_leading("/" <> rest), do: rest
```

vfs's mount-table dispatcher already normalizes paths and strips the
mount prefix before reaching the backend.

## Materialize

Calls `Exgit.Repository.materialize/2`, NOT `Exgit.FS.prefetch/3`.
The latter populates the cache without flipping `mode: :eager`, which
means streaming ops (`walk`, `grep`) still raise `ArgumentError` (see
`Exgit.FS.require_eager!/2` at `lib/exgit/fs.ex:1414-1423`). The
former does both in one step.

## Walk

`Exgit.FS.walk/2` requires the underlying repo to be `:eager`. After
a write, the head_tree is resident in the object store but the repo's
mode flag is unchanged, so `VFS.walk/3` still requires
`VFS.materialize/2` to be called first on lazy partial-clone repos.

For an agent loop this is the natural sequence anyway: clone lazy →
materialize → search/edit. Loosening `walk/2` to allow walking a
fully-resident tree without `:eager` is tracked as a possible
follow-up in `Exgit.FS`.

## Walk-emitted stat caveats

  * **`size` is 0.** Git tree entries don't carry blob size; only an
    explicit `stat/2` per path resolves the blob and returns the
    real number.
  * **`mtime` is the epoch.** Git blobs aren't dated; only commits
    are. Walking history per blob to invent an mtime is expensive
    and rarely correct.

## Git-aware ops live on the workspace, not the protocol

`commit/2`, `snapshot/1`, `restore/2`, `diff/1`, `checkout/2`, and
`materialize/1` aren't part of `VFS.Mountable`. Agents reach for
them on the workspace struct directly:

```elixir
ws = Exgit.Workspace.open(repo, "main")

# Filesystem ops via vfs (interoperable with other mounts)
fs = VFS.new() |> VFS.mount("/repo", ws)
{:ok, content, fs} = VFS.read_file(fs, "/repo/lib/foo.ex")

# Or directly on the workspace (when ws is the only thing you have)
{:ok, content, ws} = Exgit.Workspace.read(ws, "lib/foo.ex")

# Git-aware: workspace API only
snapshot = Exgit.Workspace.snapshot(ws)
{:ok, sha, ws} = Exgit.Workspace.commit(ws, message: "...", author: %{...})
```

## Conformance

vfs ships `VFS.ConformanceCase` — a parametrized macro every backend
runs through. The exgit-side conformance test lives at
`test/exgit/workspace_vfs_test.exs` and is tagged `:vfs` so it's
skipped when the dep isn't resolved (e.g. on the Elixir 1.17 CI tier
where vfs requires ~> 1.18).

A backend that ships without conformance is shipping with unverified
contract behavior — which is exactly how `VFS.Test.AppService`
silently ignored `:byte_range` / `:line_range` / `:chunk_size` until
the audit (vfs CHANGELOG, 2026-05-02). New behavior gets caught here.

The harness currently lives in vfs's `test/support/`; we load it via
`Code.require_file/1` from `test_helper.exs`. Once vfs publishes
`VFS.ConformanceCase` in `lib/`, the require-file dance can drop and
`use VFS.ConformanceCase` works directly.

## What this doesn't try to be

  * **Not an index.** No "staged vs working tree" distinction. The
    workspace IS the working tree; commit takes everything-or-nothing.
  * **Not a merger.** Single parent on commit. Multi-parent merge is
    a future concern.
  * **Not auto-committing.** Writes never produce a commit by
    themselves. The agent decides when to checkpoint via
    `Exgit.Workspace.commit/2`.
  * **Not a sync layer.** Push/pull aren't workspace ops — they're
    `Exgit.push/3` against the underlying repo.

## References

  * vfs repo: <https://github.com/ivarvong/vfs>
  * vfs SPEC: vfs `SPEC.md`
  * Working impl: `lib/exgit/workspace.ex`
  * VFS defimpl: `lib/exgit/workspace/vfs.ex`
  * Workspace tests: `test/exgit/workspace_test.exs`
  * Conformance test: `test/exgit/workspace_vfs_test.exs`
