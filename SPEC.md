# ExGit — a pure-Elixir git client

**Status**: Draft (seed document for a new project)
**Target**: Hex package `ex_git`, v0.1 on first release
**Last updated**: 2026-04-16

## 1. Summary

ExGit is a pure-Elixir implementation of the git object model and enough
of the wire protocol to clone, fetch, and push against any server that
speaks smart HTTP v2. It has no external binary dependency: no `git` on
PATH, no libgit2, no shelling out.

The library is structured as four layers — objects, storage, walking /
diff, and transport — with small behaviours at each boundary so the
pieces can be used independently.

### 1.1 Intended users

- Elixir applications that need to talk to git programmatically: CI
  tooling, deploy systems, mirror services, GitOps controllers,
  content-management systems backed by git.
- JustBash, which uses ExGit as the storage substrate for its
  versioned virtual filesystem (documented in `docs/design/vfs-git.md`).

ExGit has **no dependency on and no awareness of JustBash**. It is a
general-purpose library. The JustBash design document treats it as an
external dependency.

### 1.2 What ExGit is not

- Not a reimplementation of the `git` CLI. No porcelain commands
  (`git add`, `git commit`, `git status` in their user-facing form).
  Consumers build those on top.
- Not a working-tree manager. ExGit has objects, refs, and packs.
  Materializing a working directory from a tree is out of scope;
  consumers handle that (JustBash's VFS is one such consumer).
- Not a merge engine. No three-way merge, no conflict resolution.
  Consumers that need merging build it on top or produce merge
  commits manually (two parents, one tree they've prepared).
- Not a server. No `git-upload-pack` / `git-receive-pack`
  implementation on the server side.

### 1.3 Non-goals for v1

The following are explicit non-goals for v1 and are not accidentally
omitted:

- SSH transport
- `git://` transport
- SHA-256 repositories (pluggable via `Hash` behaviour but only SHA-1
  implemented)
- HTTP v1 protocol fallback
- Submodules, LFS, sparse/partial clone
- Signed commits and tags (can be read, not produced)
- Reflog
- Writing the index (reading only — see §6)
- Rebase, cherry-pick, revert as distinct operations
- Automatic merge algorithms
- Hooks

## 2. Core architectural principles

**P1. Small, sharp behaviours.** Each layer (object store, ref store,
transport, hash) is a behaviour with a narrow interface. Multiple
implementations coexist without touching each other.

**P2. No global state.** No Application environment, no named
processes, no registries. Everything is explicit values passed in as
arguments. This is critical for libraries: surprise state breaks
composition.

**P3. Deterministic where git is.** Given the same inputs (author,
committer, time, tree, parents, message), object SHAs must match
what real git produces byte-for-byte. This is cross-checked in tests
against `git hash-object` / `git mktree` / `git commit-tree`.

**P4. Pure Elixir, stdlib-heavy.** Runtime dependencies: `:crypto`
(SHA-1, in OTP), `:zlib` (object compression, in OTP), `Req` (HTTP
client). That's it. Dev dependencies can include `StreamData` and
fixtures.

**P5. The wire is opaque to auth.** The transport takes an auth
value (a static header, a callback, a scheme-specific struct) and
applies it. Provider-specific credential logic is an optional
sub-module, not a wire-layer concern.

**P6. No `git` on PATH anywhere in production.** Developer tooling
and tests may invoke `git` for cross-checking, but the library must
never call it at runtime. Goal: works on Fly machines, in Cloudflare
Workers (with WebAssembly when that matures), on embedded systems.

**P7. Backwards compatibility matters from v0.1.** We adopt SemVer.
The protocol-v2 floor is part of the public contract.

## 3. Layer diagram

```
┌─────────────────────────────────────────────────────────┐
│ Consumers (JustBash, CI tools, mirrors, GitOps, ...)   │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│  ExGit.Repository (façade)                              │
│  - Bundle of object_store + ref_store + config          │
│  - Convenience: clone/1, open/1, init/1                 │
└────┬───────────────────────┬──────────────────┬─────────┘
     │                       │                  │
┌────▼────────┐   ┌──────────▼─────────┐   ┌────▼────────┐
│  Object     │   │  Walking / diff     │   │  Wire       │
│  model      │   │  - Walk             │   │  - PktLine  │
│  - Blob     │   │  - Diff             │   │  - Pack RW  │
│  - Tree     │   │  - MergeBase        │   │  - Transport│
│  - Commit   │   └────────────┬────────┘   │  - Commands │
│  - Tag      │                │             └────┬────────┘
│  - Index    │                │                  │
└────┬────────┘                │                  │
     │                         │                  │
┌────▼─────────────────────────▼──────────────────▼──────┐
│  Storage behaviours                                    │
│  - ObjectStore (Memory, Disk)                          │
│  - RefStore    (Memory, Disk)                          │
│  - Config                                              │
└─────────────────────────────────────────────────────────┘
```

## 4. Object model

### 4.1 Types

Four object types:

| Object type | Struct             | Payload                           |
|-------------|--------------------|-----------------------------------|
| `blob`      | `ExGit.Object.Blob`   | Raw bytes                         |
| `tree`      | `ExGit.Object.Tree`   | Sorted list of entries `{mode, name, sha}` |
| `commit`    | `ExGit.Object.Commit` | Header lines + message            |
| `tag`       | `ExGit.Object.Tag`    | Annotated tag (ref + header + message) |

Each object has an id that is
`sha1("<type> " <> to_string(size) <> <<0>> <> content)`, per git's
canonical format.

### 4.2 Tree modes

Modes supported on **write**:

| Mode      | Meaning           |
|-----------|-------------------|
| `100644`  | Regular file      |
| `100755`  | Executable file   |
| `120000`  | Symlink           |
| `040000`  | Subdirectory      |
| `160000`  | Gitlink (submodule pointer, read/write preserved but not resolved) |

On read, modes are normalized per git convention: any file mode with
the executable bit set is treated as `100755`; any other file mode as
`100644`. This matches `core.filemode=true` normalization.

### 4.3 Commits

Standard git commit format:

```
tree <sha>
parent <sha>        # zero or more
author <name> <<email>> <unix-seconds> <tz-offset>
committer <name> <<email>> <unix-seconds> <tz-offset>
gpgsig <pem-blob>   # optional; preserved on read, never produced on write

<message>
```

Zero-parent commits (roots), one-parent commits (normal), and
multi-parent commits (merges) are all supported. ExGit has no opinion
about how merge commits are constructed — consumers supply the tree
and parents, ExGit encodes the object.

### 4.4 Annotated tags

Annotated tags are full objects (distinct from lightweight tags,
which are just refs pointing at commits). Format:

```
object <sha>
type commit
tag <name>
tagger <name> <<email>> <unix-seconds> <tz-offset>

<message>
```

Both annotated tags (as objects) and lightweight tags (refs in
`refs/tags/`) are first-class in v1. Consumers can produce either.

### 4.5 Encoding and decoding

Each object module exports:

```elixir
ExGit.Object.Blob.new(bytes)                    :: Blob.t()
ExGit.Object.Blob.encode(blob)                  :: iodata()
ExGit.Object.Blob.decode(bytes)                 :: {:ok, Blob.t()} | {:error, reason}
ExGit.Object.Blob.sha(blob)                     :: sha()

# Tree, Commit, Tag symmetrically.
```

SHAs are computed on demand and memoized in the struct for performance.
`encode/1` returns `iodata` (zlib is applied at the object-store layer).

### 4.6 The `Object` dispatch module

`ExGit.Object` is a thin router:

```elixir
ExGit.Object.decode(:blob, bytes)   # -> {:ok, Blob.t()}
ExGit.Object.decode(:commit, bytes) # -> {:ok, Commit.t()}
ExGit.Object.encode(obj)            # -> iodata
ExGit.Object.sha(obj)               # -> sha
ExGit.Object.type(obj)              # -> :blob | :tree | :commit | :tag
```

This is the API the object store calls into.

## 5. Hash

```elixir
@callback id_length() :: pos_integer()              # 20 for SHA-1
@callback hex_length() :: pos_integer()             # 40 for SHA-1
@callback hash(iodata()) :: binary()                 # raw bytes
@callback hash_hex(iodata()) :: String.t()           # lowercase hex
```

v1 implementations:

- `ExGit.Hash.SHA1` — uses `:crypto.hash(:sha, ...)`.

Future:

- `ExGit.Hash.SHA256` — for SHA-256 repositories. Shape already
  accommodates this; not implemented in v1.

Hash algorithm is chosen at the `Repository` level and propagates down.
Mixed-hash repositories are not supported.

## 6. Index (read-only)

ExGit reads git's `.git/index` file (binary format, documented in
`gitformat-index.txt`). Consumers that inspect another tool's working-
tree state can call:

```elixir
ExGit.Index.read(path :: Path.t()) :: {:ok, Index.t()} | {:error, reason}
ExGit.Index.entries(index) :: [Entry.t()]
```

Writing the index is **not** supported in v1. The index format is
highly evolved (multiple versions, extensions, split-index) and writing
it correctly is a substantial undertaking. Consumers that need to
update the index can drop to shelling out to `git update-index`, or
request this feature with a concrete use case.

## 7. Storage

### 7.1 Object store behaviour

```elixir
@type sha :: <<_::160>>
@type object_type :: :blob | :tree | :commit | :tag

@callback put(store, object :: Object.t()) :: {:ok, sha} | {:error, term()}
@callback get(store, sha) :: {:ok, Object.t()} | {:error, :not_found | term()}
@callback has?(store, sha) :: boolean()
@callback delete(store, sha) :: :ok | {:error, term()}     # optional
@callback list(store) :: Enumerable.t()                    # optional; shas
```

Implementations:

- **`ExGit.ObjectStore.Memory`** — `%{sha => {type, bytes}}` in a
  struct. Zero I/O. Primary use: tests, ephemeral sessions (like
  JustBash's default).
- **`ExGit.ObjectStore.Disk`** — loose objects under
  `<root>/objects/<ab>/<cdef...>`, zlib-deflated, matching git's
  on-disk layout exactly. Pack reading (objects inside `.pack`
  files, indexed by `.idx` files) is supported; pack writing lands
  when §9 Phase 6 arrives.

A `Disk` store, by itself, is not a valid git repository (there is no
`HEAD`, no `config`, no `refs/`). The `Repository` façade (§10)
composes a `Disk` object store with a `Disk` ref store and a config
file to produce a valid bare repository.

### 7.2 Ref store behaviour

```elixir
@type ref :: String.t()             # "refs/heads/main", "HEAD", etc.
@type ref_value :: sha | {:symbolic, ref}

@callback read(store, ref) :: {:ok, ref_value} | {:error, :not_found}
@callback write(store, ref, ref_value, opts) :: :ok | {:error, term()}
@callback delete(store, ref) :: :ok | {:error, :not_found}
@callback list(store, prefix :: ref()) :: [{ref, ref_value}]
```

The `opts` on write include `:expected` for compare-and-swap semantics
(refuse if the current value doesn't match, required for safe push
receive-side logic).

Implementations:

- **`ExGit.RefStore.Memory`** — map of refs.
- **`ExGit.RefStore.Disk`** — files under `<root>/refs/`, plus
  `<root>/HEAD`, plus optional `<root>/packed-refs` (read-only in
  v1; writes always create loose refs).

### 7.3 Remote-tracking refs

A widely observed git convention: refs under `refs/remotes/<name>/`
track the state of a remote. ExGit has no special handling; these are
just refs in the ref store. The `fetch` command writes to
`refs/remotes/<name>/<branch>` by default, matching git's behavior.
Consumers can override the destination ref pattern.

## 8. Walking and diffing

### 8.1 Walk

```elixir
ExGit.Walk.ancestors(repo, start_sha, opts) :: Enumerable.t()
  # Lazily yields commits reachable from start_sha via parent pointers.
  # opts: :limit, :topo_order, :date_order

ExGit.Walk.merge_base(repo, [sha]) :: {:ok, sha} | {:error, :none}
  # Lowest common ancestor of the given commits.
```

Both are commonly needed and not terribly hard; merge base uses the
classic "walk both, mark common ancestors" algorithm.

### 8.2 Diff

```elixir
ExGit.Diff.trees(repo, tree_a_sha, tree_b_sha, opts) ::
  [{:added | :removed | :modified, path, sha_a_or_nil, sha_b_or_nil}]
```

Tree diff is a straightforward recursive walk comparing entries.
Blob-level textual diff (line-based unified diff) is **out of scope**
for v1. Consumers that need textual diff can call a text-diff library
on the two blobs' contents.

## 9. Wire protocol

### 9.1 pkt-line

`ExGit.PktLine` encodes and decodes pkt-line framing:

```elixir
ExGit.PktLine.encode(iodata) :: iodata          # 4-hex prefix + payload
ExGit.PktLine.flush() :: binary                 # "0000"
ExGit.PktLine.delim() :: binary                 # "0001"
ExGit.PktLine.response_end() :: binary          # "0002"
ExGit.PktLine.decode_stream(bytes) :: Enumerable.t()
```

Thoroughly property-tested; foundational to everything else.

### 9.2 Pack format

#### 9.2.1 Reader

`ExGit.Pack.Reader` parses a packfile from bytes or a stream:

```elixir
ExGit.Pack.Reader.parse(bytes, opts) ::
  {:ok, [{type, sha, bytes}]} | {:error, term()}
```

Full support for:

- Base objects (types 1–4).
- `OBJ_OFS_DELTA` (type 6) — offset-based deltas within the pack.
- `OBJ_REF_DELTA` (type 7) — ref-based deltas referencing an object
  either in the same pack or in the surrounding object store.

Delta resolution requires access to base objects; the reader takes an
optional object store argument for resolving cross-pack refs. This is
**the single most complex part of the library** and warrants its own
exhaustive test suite with fixture packs from multiple real servers.

#### 9.2.2 Writer

`ExGit.Pack.Writer` produces packfiles:

```elixir
ExGit.Pack.Writer.build(objects, opts) :: iodata
  # Options: :deltas (default false in v1 — see below)
```

**v1 writes full objects only, no deltas.** Valid pack, larger than
git's. This trades pack size for implementation simplicity. Pack sizes
in typical "small push" use cases (a commit with a handful of changed
files) are modest; large pushes of many objects will produce noticeably
larger packs than git.

Delta emission is a scheduled future phase (§12 Phase 7). The
`Pack.Writer` module includes a callback-based size-estimation API so
callers can warn or refuse large pushes.

#### 9.2.3 Pack index (`.idx`)

`ExGit.Pack.Index` reads and writes pack index files (`v2` format).
Required for the on-disk object store to locate objects inside
`.pack` files without scanning. Writing the index happens after pack
write as a second step.

### 9.3 Transport behaviour

```elixir
@callback capabilities(t) :: {:ok, map()} | {:error, term()}
@callback ls_refs(t, opts) :: {:ok, [{ref, sha}]} | {:error, term()}
@callback fetch(t, wants, opts) :: {:ok, pack_bytes, summary} | {:error, term()}
@callback push(t, updates, pack_bytes, opts) :: {:ok, report} | {:error, term()}
```

Implementations:

- **`ExGit.Transport.HTTP`** — smart HTTP v2 over `Req`. The primary
  transport. Covered in §9.4.
- **`ExGit.Transport.File`** — `file://` URLs. Reads and writes a
  local bare repository directly, no HTTP. Useful for tests,
  air-gapped workflows, and local introspection.

Future (not v1):

- `ExGit.Transport.Ssh`
- `ExGit.Transport.Git` (git:// daemon protocol)

### 9.4 Smart HTTP v2

Endpoints:

```
GET  <base>/info/refs?service=git-upload-pack     (discovery for fetch)
GET  <base>/info/refs?service=git-receive-pack    (discovery for push)
POST <base>/git-upload-pack                        (fetch body)
POST <base>/git-receive-pack                       (push body)
```

Discovery sends `Git-Protocol: version=2`. If the server advertises v1
capabilities only, the transport **errors loudly** with a clear message
pointing the user at their server's v2 config. No silent v1 fallback
in v1.

#### 9.4.1 Commands

Three v2 commands are implemented:

- **`ls-refs`** — list refs, optionally filtered by `ref-prefix`.
  Used for discovery before fetch/push.
- **`fetch`** — request objects reachable from `want`s, optionally
  with `have`s (for incremental fetches), `deepen` (for shallow
  clones), and `done`. Returns a packfile.
- **`receive-pack`** update — send a pkt-line listing of ref updates
  followed by a packfile. Handled via `POST /git-receive-pack` with
  the v1-style request body (the `git-receive-pack` endpoint still
  uses the "old" receive format; this is a known protocol quirk).

#### 9.4.2 Auth

The transport takes an `auth` option which is either:

- `nil` (no auth header).
- `{:basic, user, pass}`.
- `{:bearer, token}`.
- `{:header, name, value}` — arbitrary header.
- `{:callback, fn request -> header end}` — for dynamic auth, token
  refresh, etc.

No provider-specific behavior in the transport layer. That lives in
`ExGit.Credentials` (§11) if used at all.

### 9.5 Server compatibility

ExGit must work against any server implementing protocol v2 correctly.
The tier-1 test matrix is:

| Server                 | Hosting          | Notes                              |
|------------------------|------------------|-----------------------------------|
| GitHub                 | SaaS             | Reference implementation          |
| GitLab.com             | SaaS             | Covers self-hosted GitLab too     |
| Gitea                  | Self-hosted      | Covers Forgejo (fork)             |
| Cloudflare Artifacts   | SaaS             | Launch partner use case           |
| Bitbucket Cloud        | SaaS             | Historically lagged on v2         |
| `git http-backend`     | CGI reference    | The canonical reference impl      |

Tier-2 (try not to break, no proactive testing): AWS CodeCommit, Azure
DevOps Repos, Gogs, cgit.

#### 9.5.1 Known server quirks (v1 list)

Tracked in `lib/ex_git/wire/quirks.md` and covered by named regression
tests:

1. **GitHub** returns v1 capabilities when `Git-Protocol` header is
   omitted. Always send it.
2. **GitLab** requires a git-like `User-Agent` for some endpoints to
   enable v2. Default UA: `ex_git/<version> git/2.45.0`.
3. **Gitea < 1.20** has buggy `ls-refs` filtering; filter
   client-side as a belt-and-braces fallback.
4. **Bitbucket Cloud** historically v1-only. If we detect it (via
   hostname or `Server:` header) and the server advertises v1 only,
   we error with a specific, actionable message. Bitbucket Server /
   Data Center is a different product and not tier-1.
5. **`receive-pack` report-status** format varies slightly across
   servers in whitespace and capability suffixes. Parser is
   permissive.
6. **Shallow clones** on older self-hosted stacks sometimes fail; we
   retry with a full clone and warn.

This list will grow. Every quirk gets a named test; no unexplained
conditionals in the code.

### 9.6 Conformance test suite

`test/conformance/` runs identical scenarios against each tier-1
server:

- Clone a small fixture repo.
- Push a new commit to a throwaway branch.
- Fetch after an external push.
- Force-update a branch.
- Shallow clone at depth 1.
- Push to an empty repo (first commit).
- Delete a branch via push (`:refs/heads/<name>`).

For SaaS servers this is credential-gated and runs on demand or on
scheduled CI. For `git http-backend` and Gitea, it runs against a
locally spawned server in every CI job.

A tier-1 server failing conformance is a P1 bug.

## 10. Repository façade

`ExGit.Repository` bundles an object store, ref store, and config
into a single value for consumer convenience.

```elixir
ExGit.init(path, opts) :: {:ok, Repository.t()} | {:error, term()}
  # Creates a bare repository at `path`.

ExGit.open(path, opts) :: {:ok, Repository.t()} | {:error, term()}
  # Opens an existing bare repository at `path`.

ExGit.clone(url, path, opts) :: {:ok, Repository.t()} | {:error, term()}
  # One-shot: init + fetch + set HEAD.

ExGit.Repository.new(object_store, ref_store, opts) :: Repository.t()
  # Explicit construction for custom combinations.
```

The façade also exposes convenience functions that wrap the common
paths:

```elixir
ExGit.log(repo, ref, opts)               # Walk.ancestors + formatting
ExGit.diff(repo, ref_a, ref_b)            # Diff.trees
ExGit.fetch(repo, remote_url, refspecs, opts)
ExGit.push(repo, remote_url, refspecs, opts)
```

Consumers who want fine-grained control can skip the façade entirely
and compose the primitives directly. The library is usable either way.

## 11. Credentials (optional)

`ExGit.Credentials` is an **optional sub-module** providing per-
provider auth helpers. Library users who don't need them don't pay
for them — the core transport takes plain headers or callbacks.

### 11.1 Scope

v1 includes:

- **`ExGit.Credentials.Basic`** — helper to construct Basic auth
  tuples from user/password.
- **`ExGit.Credentials.Bearer`** — helper for Bearer tokens.
- **Per-provider adapters** for the tier-1 servers, each a small
  module that knows the right username field to use:
  - `ExGit.Credentials.GitHub` — `x-access-token` trick for PATs
  - `ExGit.Credentials.GitLab` — `oauth2` username for OAuth tokens
  - `ExGit.Credentials.Gitea`
  - `ExGit.Credentials.Artifacts`
  - `ExGit.Credentials.BitbucketCloud`

Each adapter is ~10 lines and produces an auth value the transport
accepts.

### 11.2 What's not in scope

- A credential storage system (keychain, secret manager integration).
  Callers handle this themselves.
- A long-running credential helper process. Users who want git's
  credential-helper protocol can shell out to it from a callback;
  ExGit does not wrap it.
- OAuth flow orchestration.

These can be added later as separate packages (`ex_git_secrets`,
`ex_git_oauth`) if demand appears.

## 12. Roadmap

### Phase 1: object model and pkt-line

- `Object.Blob`, `Object.Tree`, `Object.Commit`, `Object.Tag` with
  encode/decode and SHA computation
- `Hash.SHA1` + `Hash` behaviour
- `PktLine` codec
- `ObjectStore.Memory`, `RefStore.Memory`
- Property tests, cross-checks against `git hash-object`

**Exit**: can construct a commit graph in memory and retrieve objects
by SHA. Zero network code. All object SHAs verified against real git.

### Phase 2: walking, diffing, repository façade

- `Walk.ancestors`, `Walk.merge_base`
- `Diff.trees`
- `Repository` façade
- `ObjectStore.Disk`, `RefStore.Disk` (loose objects, loose refs)
- `Config` reader/writer
- `init`, `open` — produce valid bare git repos readable by `git`

**Exit**: `ExGit.init("/tmp/foo.git")` produces a directory that `git
log`, `git cat-file`, and `git fsck` accept.

### Phase 3: pack format

- `Pack.Writer` (full objects, no deltas)
- `Pack.Reader` (full delta resolution)
- `Pack.Index` (v2 format read + write)
- Fixture-based tests with real server packs

**Exit**: can round-trip a real packfile from GitHub through reader
and writer. Disk store reads objects from existing `.pack` files.

### Phase 4: smart HTTP v2 transport

- `Transport.HTTP` with `ls-refs`, `fetch`, `push`
- `Transport.File` for local bare repos
- Discovery + capability parsing
- Conformance test harness with `git http-backend`
- Recorded-fixture tests for GitHub, GitLab, Gitea

**Exit**: conformance suite passes against `git http-backend` and
recorded fixtures from three SaaS servers.

### Phase 5: live conformance + credentials

- Credential adapters for tier-1 providers
- Live conformance tests against GitHub, GitLab, Gitea, Artifacts,
  Bitbucket Cloud (credential-gated)
- Index reader
- Annotated tag support verified end-to-end

**Exit**: full tier-1 live conformance passing. **v0.1 release to
hex at this point.**

### Phase 6: Polish

- Pack index writing for `Disk` store
- Garbage collection (reachability-based, opt-in)
- `packed-refs` write support
- Documentation site, usage examples, HexDocs coverage

### Phase 7: Delta compression on write

- `OBJ_OFS_DELTA` emission in `Pack.Writer`
- Heuristic for delta candidate selection
- Benchmarks against real `git` pack sizes — target within 2× on
  realistic corpora

**Exit**: typical pushes produce packs within 2× of git's size with
no correctness regressions.

### Phase 8+ (speculative, not committed)

- SHA-256 repositories
- Index writing
- SSH transport
- Bundle format (`.bundle` files)
- Partial / sparse clone filters

## 13. Testing strategy

- **Property tests** for every codec: `decode(encode(x)) == x`,
  round-trip blobs, trees, commits, tags, pkt-lines, pack objects.
- **SHA cross-checks**: every encoded object's SHA is verified against
  `git hash-object`. When `git` is available in CI, this runs live;
  a fallback fixture table is committed for offline runs.
- **Pack fixtures**: real packfiles from GitHub, GitLab, Gitea,
  Artifacts (once accessible), Bitbucket, and `git http-backend`,
  checked in under `test/fixtures/packs/`. Exhaustive delta
  resolution tests against each.
- **Wire tests**: local `git http-backend` spawned in test setup for
  v2 protocol tests. Tagged `:network_local` for skip-ability.
- **Conformance**: `test/conformance/` runs identical scenarios
  against each tier-1 server (§9.6). SaaS runs gated on credentials.
- **Adversarial**: fuzz pkt-line decoder, pack reader (malformed
  inputs must error cleanly, never crash the VM).

A failing conformance test against any tier-1 server is a P1 bug.

## 14. Versioning and release policy

### 14.1 SemVer

- **v0.x**: pre-1.0. API may break between minors. Hex publishes
  permitted; consumers should pin exact minor version.
- **v1.0**: API freeze. Breaking changes require a major version.

### 14.2 Protocol-v2 floor

Protocol v2 support is part of the public contract. Dropping v2
support or changing required server capabilities is a major bump.
Adding optional negotiation (packfile URIs, SHA-256) is a minor bump.

### 14.3 Release cadence

- v0.1: after Phase 5 (live conformance + credentials)
- Subsequent v0.x: each phase completion
- v1.0: after Phase 7 (delta writing), assuming API has been stable
  for two releases

## 15. Open questions

1. **Fetch negotiation (`have` lines).** v1 fetches are always full
   (shallow-capable). Incremental fetch via `have` negotiation is
   valuable for large repos with frequent small updates. Phase 6
   or Phase 7 item; not v0.1.

2. **Config file format completeness.** Git's `.git/config` supports
   includes, conditionals (`includeIf`), and some niche escapes.
   Proposal: v1 implements the 90% (sections, subsections,
   key/value, quoting) and errors cleanly on unsupported constructs.

3. **Thread safety / concurrent writes.** ObjectStore and RefStore
   are values; two processes holding the same Disk-backed stores
   can race on writes. Proposal: document that callers must
   serialize writes (typical via a GenServer wrapper); don't bake
   locking into the library.

4. **Error reporting granularity.** Should every error be a struct
   with machine-readable codes, or are tagged tuples (`{:error,
   :not_found}`) enough? Lean toward tagged tuples for simple cases
   and structs for complex ones (protocol errors with quirk
   attribution, for instance).

5. **Streaming fetch.** Pack size on large fetches can be gigabytes.
   The transport currently returns a single `pack_bytes` binary.
   Proposal: add a streaming variant in Phase 5+ that emits objects
   as they're resolved; keep the batch API for simple cases.

6. **Working-tree helpers as a companion package.** Not in ExGit, but
   there's real demand among Elixir users for "give me the tree of
   commit X as a map of paths to bytes." Candidate for a thin
   companion package (`ex_git_checkout`) that's just a tree walker.
   Not committing; just flagging.

## 16. Glossary

- **pkt-line**: git's wire-level framing format; 4-hex-digit length
  prefix plus payload.
- **Smart HTTP v2**: git's modern wire protocol over HTTPS, specified
  in `gitprotocol-v2.txt`.
- **Thin pack**: a pack that contains objects whose bases are expected
  to be present in the receiver's object store already. ExGit's
  reader handles thin packs; its writer does not produce them.
- **OBJ_OFS_DELTA / OBJ_REF_DELTA**: delta-compressed objects in a
  pack. OFS uses a negative offset within the pack to find the base;
  REF uses a full SHA.
- **Shallow clone**: a clone limited to a commit depth, producing a
  repository that omits ancestors beyond that depth.