# Exgit

Pure-Elixir git. Clone, fetch, and push over smart HTTP v2 — no `git` binary, no libgit2, no shelling out.

```elixir
{:ok, repo} = Exgit.clone("https://github.com/elixir-lang/elixir")

{:ok, head} = Exgit.RefStore.resolve(repo.ref_store, "HEAD")
{:ok, commit} = Exgit.ObjectStore.get(repo.object_store, head)
# => %Exgit.Object.Commit{message: "...", tree: <<...>>, ...}
```

Clones into memory by default. Every operation returns a new repo struct — no processes, no side effects, no disk unless you ask for it.

## Installation

```elixir
def deps do
  [{:exgit, "~> 0.1.0"}]
end
```

## Quick start

### Clone and read a file

```elixir
{:ok, repo} = Exgit.clone("https://github.com/user/repo")

# Resolve HEAD to a commit
{:ok, sha} = Exgit.RefStore.resolve(repo.ref_store, "HEAD")
{:ok, commit} = Exgit.ObjectStore.get(repo.object_store, sha)

# Walk the tree to find a file
{:ok, tree} = Exgit.ObjectStore.get(repo.object_store, Exgit.Object.Commit.tree(commit))
{_mode, _name, blob_sha} = Enum.find(tree.entries, &match?({_, "README.md", _}, &1))

{:ok, blob} = Exgit.ObjectStore.get(repo.object_store, blob_sha)
IO.puts(blob.data)
```

### Clone to disk

```elixir
{:ok, repo} = Exgit.clone("https://github.com/user/repo", path: "/tmp/my-clone")
```

### Lazy clone (for agents)

```elixir
# Fetches refs only — no objects — in milliseconds. Returns a
# %Repository{mode: :lazy}.
{:ok, repo} = Exgit.clone("https://github.com/torvalds/linux", lazy: true)

# Objects are fetched on demand and cached in the repo struct. Thread
# the updated repo forward so subsequent calls reuse the cache:
{:ok, {_mode, readme}, repo} = Exgit.FS.read_path(repo, "HEAD", "README")
{:ok, {_mode, mkfile}, repo} = Exgit.FS.read_path(repo, "HEAD", "Makefile")

# For streaming ops (walk/grep) convert to an eager repo first —
# streaming uses pure reads and wouldn't make progress on a lazy
# repo. `materialize/2` prefetches everything reachable from `ref`
# and flips the repo's mode to :eager in one step:
{:ok, repo} = Exgit.Repository.materialize(repo, "HEAD")
matches = Exgit.FS.grep(repo, "HEAD", "TODO", path: "**/*.c") |> Enum.take(10)
```

### Partial clone (server-side filter)

```elixir
# The server ships a pack with refs + commits + trees but NO blobs.
# Blobs are fetched on demand as `FS.read_path/3` touches them. Much
# cheaper than a full clone of a multi-GB repo.
{:ok, repo} = Exgit.clone("https://github.com/torvalds/linux",
  filter: {:blob, :none})
```

The Promisor cache lives inside the `%Repository{}` struct — pure value,
no processes. Two tasks holding the same struct see the same cache;
discarding the returned struct simply means subsequent lookups will
refetch. Perfect for agent loops that want snapshot semantics.

The on-disk format is a standard bare git repo — `git log`, `git fsck`, and friends all work on it.

### Private repos

```elixir
auth = Exgit.Credentials.GitHub.auth("ghp_your_token")
{:ok, repo} = Exgit.clone("https://github.com/org/private-repo", auth: auth)
```

Credential helpers for GitHub, GitLab, Gitea, Bitbucket Cloud, and generic basic/bearer auth:

```elixir
Exgit.Credentials.GitHub.auth(token)           # PAT via x-access-token
Exgit.Credentials.GitLab.auth(token)           # OAuth via oauth2 username
Exgit.Credentials.Gitea.auth(token)            # Bearer token
Exgit.Credentials.BitbucketCloud.auth(u, p)    # App password
Exgit.Credentials.basic(user, pass)            # Generic basic auth
Exgit.Credentials.bearer(token)                # Generic bearer token
```

### Create objects and push

```elixir
alias Exgit.{ObjectStore, RefStore}
alias Exgit.Object.{Blob, Tree, Commit}

{:ok, repo} = Exgit.clone("https://github.com/user/repo",
  auth: Exgit.Credentials.GitHub.auth(token))

# Build a new commit
blob = Blob.new("hello world\n")
{:ok, blob_sha, store} = ObjectStore.put(repo.object_store, blob)
repo = %{repo | object_store: store}

tree = Tree.new([{"100644", "hello.txt", blob_sha}])
{:ok, tree_sha, store} = ObjectStore.put(repo.object_store, tree)
repo = %{repo | object_store: store}

{:ok, parent} = RefStore.resolve(repo.ref_store, "refs/heads/main")

commit = Commit.new(
  tree: tree_sha,
  parents: [parent],
  author: "Alice <alice@example.com> #{System.os_time(:second)} +0000",
  committer: "Alice <alice@example.com> #{System.os_time(:second)} +0000",
  message: "Add hello.txt\n"
)

{:ok, commit_sha, store} = ObjectStore.put(repo.object_store, commit)
repo = %{repo | object_store: store}

{:ok, ref_store} = RefStore.write(repo.ref_store, "refs/heads/main", commit_sha, [])
repo = %{repo | ref_store: ref_store}

# Push
transport = Exgit.Transport.HTTP.new("https://github.com/user/repo",
  auth: Exgit.Credentials.GitHub.auth(token))
{:ok, result} = Exgit.push(repo, transport, refspecs: ["refs/heads/main"])
```

### Walk commit history

```elixir
Exgit.Walk.ancestors(repo, head_sha)
|> Stream.take(10)
|> Enum.each(fn commit ->
  IO.puts("#{Exgit.Object.Commit.sha_hex(commit)} #{String.trim(commit.message)}")
end)
```

### Diff two trees

```elixir
{:ok, changes} = Exgit.Diff.trees(repo, old_tree_sha, new_tree_sha)

for %{op: op, path: path} <- changes do
  IO.puts("#{op} #{path}")
end
# added    lib/new_file.ex
# modified lib/existing.ex
# removed  old_file.ex
```

## Performance

Every hot path emits [`:telemetry`](https://hexdocs.pm/telemetry/) span
events. The numbers below are from **100 measured runs** against
[`ivarvong/pyex`](https://github.com/ivarvong/pyex) (warm-up run
discarded). Report bench harness lives in `bench/review_bench.exs`.

| Property                                | Value       |
|-----------------------------------------|-------------|
| Total code (`cloc`)                     | 77,305 LOC  |
| `lib/` only (Elixir)                    | 27,022 LOC  |
| Files in tree                           | 259         |
| Git objects in HEAD pack                | 1,490       |
| Pack size over the wire                 | 1.2 MB      |

```elixir
{:ok, repo} = Exgit.clone("https://github.com/ivarvong/pyex", lazy: true)
{:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
Exgit.FS.grep(repo, "HEAD", "anthropic", case_insensitive: true)
|> Enum.to_list()
```

Phase breakdown (median / p95 over 100 runs):

| Phase                                | median   | p95      | min      |
|--------------------------------------|---------:|---------:|---------:|
| 1. `clone(url, lazy: true)`          |   80 ms  |   99 ms  |   54 ms  |
| 2. `prefetch(blobs: true)`           |  674 ms  |  756 ms  |  647 ms  |
| 3. `grep` case-insensitive           |  156 ms  |  164 ms  |  145 ms  |
| **total**                            | **911 ms** | **1.12 s** | **859 ms** |

Under the hood (telemetry medians across 100 runs):

| Event                 | median   | p95      | note                                  |
|-----------------------|---------:|---------:|---------------------------------------|
| `transport.ls_refs`   |   80 ms  |   99 ms  | includes protocol-v2 `symrefs` probe  |
| `transport.fetch`     |  309 ms  |  353 ms  | 1.2 MB pack, 1490 objects over HTTPS  |
| `pack.parse`          |  127 ms  |  156 ms  | inflate + decode all objects          |
| `fs.walk`             |  156 ms  |  164 ms  | walk the full tree in-memory          |
| `fs.grep`             |  156 ms  |  164 ms  | scan 259 files, 2.9 MB, 2 matches     |
| `object_store.get`    |  109 µs  |  1.4 ms  | 216×; pure in-memory                  |

**~910 ms total, wall-clock, over real network.** Dominated by the
network round-trip and pack inflation; the actual grep work is ~156 ms
over 2.9 MB of source code. `pack.parse` is ~40% slower than our
pre-review baseline — the deliberate cost of the new
`safeInflate`-based tracked inflate that never calls
`:zlib.uncompress/1` on hostile input (see review #4). Match count
is deterministic (2) across all 100 runs.

For partial clones (`filter: {:blob, :none}`), a fetch against a
large repo drops from tens of seconds to a few seconds — see
[`BENCHMARKS.md` in the smoketest
repo](https://github.com/ivarvong/exgit_smoketest/blob/main/BENCHMARKS.md).

### Attaching your own handler

```elixir
:telemetry.attach_many(
  "my-tap",
  [
    [:exgit, :transport, :fetch, :stop],
    [:exgit, :object_store, :get, :stop],
    [:exgit, :fs, :grep, :stop]
  ],
  fn event, m, md, _ ->
    us = System.convert_time_unit(m.duration, :native, :microsecond)
    IO.puts("#{inspect(event)}  #{us} us  #{inspect(md)}")
  end,
  nil
)
```

Zero cost when no handler is attached. Bridges to OpenTelemetry via
`opentelemetry_telemetry`.

## Architecture

Four layers, each usable independently:

```
Objects        Storage         Walking          Transport
Blob           ObjectStore.*   Walk.ancestors   Transport.HTTP
Tree           RefStore.*      Walk.merge_base  Transport.File
Commit                         Diff.trees
Tag
```

**ObjectStore** and **RefStore** are protocols with two implementations:
- **Memory** — pure values, default for clones. Objects stored zlib-compressed, decoded on demand.
- **Disk** — standard git loose-object format. Reads packfiles. Atomic writes.

Every mutating operation returns the updated store. Thread the repo struct through your code, or wrap it in a GenServer — your call.

## What this is not

- Not a `git` CLI replacement. No porcelain commands — consumers build those on top.
- Not a working-tree manager. No checkout, no staging area writes.
- Not a merge engine. No three-way merge or conflict resolution.
- Not a server. Client-side only.

## Status

Pre-1.0. Two rounds of staff-engineering review are closed; the
library has a defended threat model (see
[SECURITY.md](./SECURITY.md)) and a growing regression corpus of
CVE-class tests, but we've **not** claimed "production-hardened" —
that's a v1.0 stamp that waits on (a) a stated SLA for each
defended boundary, (b) explicit fuzz-corpus regression cases for
every historical finding, and (c) stability of the Promisor/
`{:ok, result, repo}` threading model.

What's in place:

- **Ref-name validation** at the transport boundary AND
  defense-in-depth at every `RefStore.Disk` entry point. Symbolic
  refs read off disk are re-validated before being followed.
- **Tree entry-name validation** at `Tree.decode/1`. Hostile trees
  containing `..`, `/foo`, `\0`, or case-insensitive `.git` /
  `.gitmodules` are rejected before they reach FS operations or a
  future checkout.
- **Commit / Tag hex-header validation** at `decode/1`. Accessor
  calls (`Commit.tree/1`, `Commit.parents/1`, `Tag.object`) are
  infallible — a hostile remote cannot DoS walks, diffs, pushes,
  or FS lookups with a non-hex header.
- **Credentials are host-bound by default**, with ASCII-case-folded
  + trailing-dot-stripped normalization. `%Credentials{}` has a
  custom `Inspect` impl that redacts tokens.
- **Every decoder returns `{:error, _}`, never raises.**
  Property/fuzz tests across `Pack.Reader`, `Pack.Delta`,
  `Pack.Common`, `Index.parse`, config, commit, tag, tree.
- **Pack parse memory is bounded**: `:max_pack_bytes` (2 GiB),
  `:max_object_bytes` (100 MiB), `:max_resolved_bytes` (500 MiB).
- **Loose-object zlib decompression** is wrapped in try/rescue —
  corrupt on-disk objects return `{:error, :zlib_error}`.
- **Pack-reader zlib tracking** uses `:zlib.safeInflate/2` +
  `:zlib.inflateEnd/1` probes. No `:zlib.uncompress/1` on untrusted
  input; per-probe output is bounded.
- **`merge_base/2` is O(Q)** per iteration (not O(Q²)). Large
  shared-history repos work in milliseconds.
- **`:file.pread/3`** for disk pack lookups, with a size-probed
  tail read — objects larger than 128 KiB decode correctly.
- **Promisor cache** supports `:max_cache_bytes` with FIFO-by-commit
  eviction for long-running agent loops.
- **Protocol v2 `symrefs`** — `Exgit.clone/2` picks the server's
  actual HEAD target instead of guessing main/master.
- **399 tests, 29 properties, 0 failures** across default, slow,
  real_git, and live-integration tiers.
- **CI gates**: Elixir 1.17 / OTP 27 on ubuntu-24.04 with
  warnings-as-errors, Credo, Dialyzer, format check, partial-clone
  roundtrip against GitHub.

See [CHANGELOG.md](./CHANGELOG.md) for details and
[SECURITY.md](./SECURITY.md) for the threat model.

## Versioning

Exgit follows [Semantic Versioning](https://semver.org). The **public
API** for SemVer purposes is:

- `Exgit.clone/2` (with `:lazy`, `:filter`, `:path`, `:if_unsupported`,
  `:remote` options), `fetch/3`, `push/3`, `init/1`, `open/1`
- `Exgit.FS.*` (every public `read_path`, `ls`, `stat`, `exists?`,
  `prefetch`, `walk`, `glob`, `grep`, `write_path`)
- `Exgit.Object.*` (Blob, Tree, Commit, Tag struct shape)
- `Exgit.Credentials.*`
- `Exgit.Transport` protocol + `Exgit.Transport.HTTP.new/2`
- The `:telemetry` event shapes documented in `Exgit.Telemetry`

Anything not in this list (including private modules, `@doc false`
helpers, internal protocol functions) may change in any release.

**0.x releases are permitted to break the public API** with a
CHANGELOG entry and migration notes. From 1.0 onward, breaking
changes require a major-version bump.

Functions annotated `@doc experimental: true` — currently
`FS.prefetch/3` and `Repository.materialize/2` — are explicitly
exempt from SemVer guarantees until marked stable. The `:lazy` and
`:filter` options on `Exgit.clone/2` are also experimental: the
threading contract (`{:ok, result, repo}` shape) may evolve before
v1.0.

See [CHANGELOG.md](./CHANGELOG.md) for release notes and
[SECURITY.md](./SECURITY.md) for the threat model and disclosure
policy.

## License

MIT
