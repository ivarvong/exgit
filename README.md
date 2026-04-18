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
# Fetches refs only — no objects — in milliseconds.
{:ok, repo} = Exgit.lazy_clone("https://github.com/torvalds/linux")

# Objects are fetched on demand and cached in the repo struct. Thread
# the updated repo forward so subsequent calls reuse the cache:
{:ok, {_mode, readme}, repo} = Exgit.FS.read_path(repo, "HEAD", "README")
{:ok, {_mode, mkfile}, repo} = Exgit.FS.read_path(repo, "HEAD", "Makefile")

# For streaming ops (walk/grep) prefetch first — they use pure reads
# and don't grow the cache themselves:
{:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
matches = Exgit.FS.grep(repo, "HEAD", "TODO", path: "**/*.c") |> Enum.take(10)
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
events. The numbers below are from a single instrumented run against
[`ivarvong/pyex`](https://github.com/ivarvong/pyex):

| Property                                | Value       |
|-----------------------------------------|-------------|
| Total code (`cloc`)                     | 77,305 LOC  |
| `lib/` only (Elixir)                    | 27,022 LOC  |
| Files in tree                           | 259         |
| Git objects in HEAD pack                | 1,490       |
| Pack size over the wire                 | 1.2 MB      |

```elixir
{:ok, repo} = Exgit.lazy_clone("https://github.com/ivarvong/pyex")
{:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
Exgit.FS.grep(repo, "HEAD", "anthropic", case_insensitive: true)
|> Enum.to_list()
```

Phase breakdown:

```
  1. lazy_clone                                   61 ms   ( 7%)
  2. prefetch(blobs: true)                       631 ms   (76%)
  3. grep case-insensitive "anthropic"           144 ms   (17%)
  ------------------------------------------------------------
  total                                          837 ms
```

Under the hood:

```
  transport.ls_refs    61 ms         (list refs on remote)
  transport.fetch     329 ms         (1.2 MB pack, 1490 objects over HTTPS)
  pack.parse           91 ms         (inflate + decode all objects)
  fs.walk             143 ms         (walk the full tree in-memory)
  fs.grep             143 ms         (scan 259 files, 2.9 MB, 2 matches)
  object_store.get    578×           (17 μs avg — pure in-memory)
```

**~850 ms total, wall-clock, over real network.** Dominated by the
network round-trip and pack inflation; the actual grep work is ~140 ms
over 2.9 MB of source code.

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

v0.1 — production-hardened. All P0 security and crash-safety work
from the staff-engineering review is closed:

- **Ref-name validation** at the transport boundary. A hostile
  remote cannot escape the repo root via a crafted ref name.
- **Credentials are host-bound by default.** Bare auth tuples are
  auto-wrapped into host-scoped `%Exgit.Credentials{}` on
  `Transport.HTTP.new/2`. Cross-origin redirects cannot leak tokens
  regardless of Req's behavior.
- **Every decoder returns `{:error, _}`, never raises.** 1000-case
  property/fuzz tests across `Pack.Reader`, `Pack.Delta`,
  `Pack.Common`, `Index.parse`, and config parsing.
- **Pack parse memory is bounded** (`:max_pack_bytes` default 2 GiB,
  `:max_object_bytes` default 100 MiB).
- **`:file.pread/3`** for disk pack lookups — single-object latency
  is now independent of pack size.
- **360+ tests, 29 properties, 0 failures** across default, slow,
  real_git, and live-integration tiers.
- **CI gates**: Elixir 1.19 / OTP 28 on ubuntu-24.04 with
  warnings-as-errors, Credo, Dialyzer, format check, partial-clone
  roundtrip against GitHub.

See [CHANGELOG.md](./CHANGELOG.md) for details and
[SECURITY.md](./SECURITY.md) for the threat model.

## Versioning

Exgit follows [Semantic Versioning](https://semver.org). The **public
API** for SemVer purposes is:

- `Exgit.clone/2`, `lazy_clone/2`, `fetch/3`, `push/3`, `init/1`, `open/1`
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
`lazy_clone/2`, `FS.prefetch/3`, and `Repository.materialize/2` —
are explicitly exempt from SemVer guarantees until marked stable.

See [CHANGELOG.md](./CHANGELOG.md) for release notes and
[SECURITY.md](./SECURITY.md) for the threat model and disclosure
policy.

## License

MIT
