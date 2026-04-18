# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Production-readiness round

A follow-up audit after the staff-engineering review closed the
reviewer's "what I didn't look at" list:

- **Config RCE audit** — `Exgit.Config` is read-only data; no code
  path executes values from it (no `core.sshCommand`,
  `core.fsmonitor`, `core.hookspath`, `insteadOf`, `includeIf`
  expansion). A new structural test
  (`test/exgit/security/no_shell_exec_test.exs`) asserts `lib/`
  contains zero `System.cmd` / `:os.cmd` / `Port.open` /
  `Path.expand` / `Path.absname` calls; failure means someone
  introduced a new execution path that needs review against the
  threat model.
- **Pack.Writer concurrent-build stress** — 3 tests assert 100
  parallel builds of identical input produce byte-identical
  output, 100 parallel builds of distinct input round-trip
  cleanly, and 1000 sequential builds don't leak zlib ports.
- **Decoder fuzz corpus** — 10 property tests, 500 cases each,
  exercise `Blob.decode/1`, `Tree.decode/1`, `Commit.decode/1`,
  `Tag.decode/1`, and `Pack.Reader.parse/2` on random bytes.
  Every decoder's "never raises on untrusted input" promise is
  now explicitly tested.
- **Config fuzz corpus** — 3 property tests, 500 cases each,
  cover `Config.parse/1` on random bytes, section-header-like
  noise, and roundtrip fixpoint. Includes RCE-shape regression
  tests that parse `core.fsmonitor` / `core.sshCommand` /
  `includeIf` values and assert they are stored verbatim (not
  executed or expanded).
- **Walk cross-check vs real git** — `test/exgit/walk_real_git_test.exs`
  constructs 5 DAG shapes (fork, criss-cross, linear, deep-fork,
  octopus) with real git, then compares `Exgit.Walk.merge_base/2`
  and `merge_base_all/2` against `git merge-base` and
  `git merge-base --all`. Found and fixed a nondeterministic
  LCA-pick bug (criss-cross merges).

### Fixed

- **`Walk.merge_base/2`** picked from the candidate `MapSet` with
  `hd(MapSet.to_list(...))`, whose order depends on insertion
  hashing. Multiple-LCA cases (criss-cross merges) returned
  different SHAs on different runs. Now sorts candidates by
  `{-timestamp, sha}` (newest first, SHA-ascending tiebreak) for
  a deterministic pick. Documented divergence from git's exact
  tiebreak (traversal-order-dependent) in the docstring.

### Added

- **`Walk.merge_base_all/2`** — returns every valid LCA, matching
  `git merge-base --all`. Cross-checked against real git on 5 DAG
  shapes.
- **`Diff.trees/4` bounds** — `:max_depth` (default 256),
  `:max_changes` (default `nil`), and tree-cycle detection via
  the descent-path `seen` set. Hostile trees can no longer
  overflow the stack or loop forever during a diff.
- **`Index.parse/2` bounds** — `:max_entries` (default 1M),
  `:max_bytes` (default 512 MiB), and SHA-1 checksum verification
  (`:verify_checksum`, default `true`). Catches hostile indexes
  claiming 4-billion entries, oversized inputs, and bit-rot.

### Changed — **breaking (pre-release API redesign)**

These changes were driven by an API audit after the staff-engineering
review round. Exgit has not yet cut an official release, so we're
taking the opportunity to land the right shapes before v0.1.

- **`Exgit.lazy_clone/2` removed.** Fold into `Exgit.clone/2` via
  new options:
    - `clone(url)` — full clone (eager; default behavior).
    - `clone(url, lazy: true)` — refs only; objects fetched on demand.
      Returns `%Repository{mode: :lazy}`.
    - `clone(url, filter: {:blob, :none})` — partial clone; commits
      and trees eager, blobs on demand.
    - `clone(url, filter: ..., lazy: true)` — refs only; everything
      on demand.
    - `clone(url, path: "...", lazy: true)` — returns
      `{:error, :disk_partial_clone_unsupported}` (explicit; no
      silent `:path`-ignored footgun).

  Matches `git clone`'s single-command mental model.

- **`%Exgit.Repository{}` gained `:mode` field** (`:eager | :lazy`).
  Defaults to `:eager` in `Repository.new/3`. `clone(url, lazy: true)`
  and `clone(url, filter: ...)` produce `:lazy`. `Repository.materialize/2`
  flips `:lazy → :eager`. Streaming FS ops (`FS.walk/2`, `FS.grep/4`)
  now pattern-match on `:eager` and raise on `:lazy` with a pointer
  at `materialize/2` or `prefetch/3`. Callers of `FS.walk/2`/`FS.grep/4`
  on lazy repos get a clear error message; the previous
  `ArgumentError` checked struct-internal cache emptiness.

- **`FS.prefetch/3` with `blobs: true` flips `:mode` to `:eager`** on
  a previously-lazy repo. After a full prefetch every reachable
  object is resident, so streaming ops proceed without a second
  conversion step. `blobs: false` (trees-only) leaves `:mode`
  unchanged.

- **`Exgit.Transport.ls_refs/2` return shape changed** from
  `{:ok, refs}` to `{:ok, refs, meta}`. `refs` is always a list of
  `{ref_name, sha}` 2-tuples (the protocol spec never described any
  other shape); `meta` is a map carrying protocol-v2 side-channel
  data:
    - `meta.head` — HEAD's symref target (e.g. `"refs/heads/main"`),
      present when the server advertises it via the protocol-v2
      `symrefs` argument.
    - `meta.peeled` — `%{tag_ref => peeled_target_sha}`, populated
      when the server emits `peeled:<sha>` attributes on annotated
      tags.
  `Exgit.Transport.File.ls_refs/2` surfaces `meta.head` by reading
  the on-disk HEAD symref. Every user-defined Transport
  implementation must update to the new 3-tuple return shape.

### Added

- **`Exgit.RefName`** — validation of git ref names at the transport
  boundary. Ports `git check-ref-format` rules; emits
  `[:exgit, :security, :ref_rejected]` telemetry on hostile names.
- **`Exgit.Filter`** — structured partial-clone filter specs
  (`{:blob, :none}`, `{:blob, {:limit, n}}`, `{:tree, depth}`,
  `{:raw, "spec"}`).
- **`Exgit.Repository.materialize/2`** — convert a Promisor-backed repo
  into a plain `ObjectStore.Memory`-backed one in a single call.
- **`Exgit.Transport.HTTP.request_opts/5`** and **`.auth_headers_for/2`** —
  exposed for test introspection; host-bound credential check is now
  the single enforcement point.
- **`Exgit.Transport.HTTP.capabilities_cached/1`** — memoizing
  capabilities accessor. Reduces HTTP round-trips in agent workflows
  that issue many fetches against one transport (review #13).
- **`Exgit.Error`** — canonical error struct (`%Exgit.Error{code,
  context, message}`). New error paths SHOULD use it; existing ad-hoc
  shapes (`{:error, atom}`, `{:error, {atom, details}}`) are preserved
  for SemVer. v1.0 may coalesce (review #18).
- **`Exgit.Credentials.bind_to/2`** — pipeline-friendly host-binding:
  `Credentials.bearer(token) |> Credentials.bind_to("github.com")`
  (review #44).
- **`Exgit.ObjectStore.Promisor.empty?/1`** — stable abstraction
  replacing struct-peeking on `%Promisor{cache: %Memory{objects: _}}`
  (review #17).
- **`Exgit.ObjectStore.Promisor.resolve_with_fetch/2`** — variant of
  `resolve/2` that threads the grown promisor back on the
  fetch-but-not-found path so the cache side-effect isn't wasted
  (review #33).
- `:max_pack_bytes` (default 2 GiB), `:max_object_bytes` (default
  100 MiB), and `:max_resolved_bytes` (default 500 MiB) options on
  `Exgit.Pack.Reader.parse/2` bound memory on untrusted input
  (review #11/#35).
- `:max_cache_bytes` option on `Exgit.ObjectStore.Promisor.new/2` —
  enables FIFO-by-commit eviction so long-running agent loops don't
  OOM (review #34).
- `:redirect` option on `Exgit.Transport.HTTP.new/2` — `false`
  (default), `:same_origin`, or `:follow`. Host-bound credentials
  enforce the cross-origin leak check regardless (review #14).
- Protocol v2 `symrefs` argument on `ls-refs` — `Exgit.clone/2` now
  picks the server's actual HEAD target instead of guessing
  `main`/`master`/first-advertised (review #9).
- `[:exgit, :security, :ref_rejected]`, `[:exgit, :ref_store,
  :write_failed]`, and `[:exgit, :object_store, :haves_sent]`,
  `[:exgit, :object_store, :cache_overfull]` telemetry events.
- Peeled-tag parsing in `packed-refs` (review #37). Peeled targets
  are threaded through for a future fetch-negotiator; not yet
  surfaced in `list_refs/2`.
- Dialyzer and Credo in CI (currently report-only; will gate in a
  future release).

### Changed — **breaking**

- **`Exgit.FS.read_path/3`**, **`ls/3`**, **`stat/3`**, **`write_path/4`**
  now return `{:ok, result, repo}` to support Promisor cache growth
  across calls. Callers must thread the returned `repo` forward to
  benefit from the populated cache.
- **`Exgit.Transport.HTTP.new/2`** automatically wraps bare auth tuples
  (`{:basic, u, p}`, `{:bearer, t}`, etc.) in a host-bound
  `%Exgit.Credentials{}`. Legacy callers are transparently protected
  against cross-origin credential leaks. To opt out, wrap the tuple
  with `Exgit.Credentials.unbound/1`.
- **`{:callback, fun}` auth** now receives the request URL as its sole
  argument (was previously mis-called with zero arguments — crash on
  first use).
- **`ObjectStore.Disk.import_objects/2`** returns
  `{:error, {:partial_import, [{sha, reason}]}}` on any per-object
  failure instead of crashing or silently succeeding.
- **`Exgit.FS.walk/2`** and **`.grep/4`** now raise `ArgumentError` if
  called on a Promisor-backed repo whose cache is empty, pointing the
  caller at `FS.prefetch/3` or `Repository.materialize/2`. Prefixes
  no longer silently return empty results.
- HTTP requests explicitly set `redirect: false` on Req — no longer
  depends on Req's default cross-origin auth-stripping behavior.
- **`Exgit.Transport.HTTP.ls_refs/2`** now returns a mix of 2-tuples
  `{ref, sha}` and 3-tuples `{ref, sha, meta}` — the 3-tuple shape
  carries protocol-v2 attributes like `symref-target` and `peeled`.
  Consumers that care only about the `{ref, sha}` pair can use
  `elem/2` or run through a tuple-shape-agnostic iteration.
- **`Tree.new/1`** accepts `:strict` option; when `true`, unknown
  modes raise `ArgumentError` instead of being silently coerced
  (review #10). Default behavior unchanged.

### Fixed

- Pack parser no longer raises `ArgumentError` / `MatchError` on
  malformed input. Every decoder returns `{:error, _}`.
- `Pack.Delta.apply/2` validates copy offsets, insert lengths, and
  the result-size cap — hostile deltas produce tagged errors.
- `Pack.Common.decode_type_size_varint/1` and
  `decode_ofs_varint/1` return `{:error, :truncated}` on empty input
  instead of crashing on `FunctionClauseError`.
- Loose-object parser validates the declared size against the
  content length and rejects unknown object types with a structured
  error.
- `Pack.Index` no longer generates descending `0..-1` ranges on empty
  packs (removes Elixir 1.19 deprecation warning).
- **Commit.decode/1** and **Tag.decode/1** validate hex-header
  values — a structurally-valid commit with non-hex `tree`/`parent`
  bytes is rejected with `{:error, {:invalid_hex_header, name,
  value}}` instead of crashing downstream accessors (review #23).
- **Tree.decode/1** validates every entry name against
  path-traversal rules — rejects empty, `.`, `..`, any `/`, any NUL,
  and case-insensitive `.git`/`.gitmodules` (review #2).
- **RefStore.Disk** validates ref names at every public entry
  (`read_ref/2`, `resolve_ref/2`, `write_ref/4`, `delete_ref/2`) and
  revalidates symbolic targets read from disk. Hostile targets
  return `{:error, :invalid_ref_name}` with telemetry (review #1).
- **ObjectStore.Disk.get_object/2** wraps `:zlib.uncompress/1` in
  `try/rescue`, returning `{:error, :zlib_error}` on corrupt/hostile
  loose objects instead of raising (review #3).
- **Pack.Reader** zlib tracking uses `:zlib.safeInflate/2` +
  `:zlib.inflateEnd/1` probes — no `:zlib.uncompress/1` calls on
  hostile input; per-probe output is bounded by `safeInflate`'s
  implementation-defined threshold (review #4).
- **Pack.Writer.deflate/1** wraps zlib calls in `try/after` so the
  zlib port is freed even when `deflate/3` raises. Previously a
  long-running server would slowly leak ports under memory pressure
  (review #30).
- **Credentials.host_matches?/2** normalizes both pattern and URL
  host: ASCII-case-folded, trailing-dot-stripped. `GITHUB.COM`,
  `github.com.`, `GitHub.com.` all match a `"github.com"` binding.
  Host-confusion attacks like `evil.comgithub.com` still correctly
  fail to match (review #5).
- **Custom `Inspect` impl** for `%Exgit.Credentials{}` — default
  Inspect would dump the raw token into crash logs (review #15).
- **Walk.merge_base/2** maintains `stale_in_queue` incrementally;
  the early-termination check is now O(1) instead of O(Q) per
  iteration. Merge-base on histories with hundreds of shared
  ancestors is no longer O(Q²) (review #25).
- **Walk.parse_timestamp/1** uses a module-attribute regex compiled
  once at load time instead of per-call (review #27).
- **Config** pre-compiles section-header regexes at module load
  (review #29).
- **Config.parse/1** uses `case` instead of an unconditional match
  on `parse_key_value/1`'s result — future branches that return
  `{:error, _}` cannot crash the parser, matching the moduledoc's
  "never raises on untrusted input" contract (review #28).
- **Pack.Reader** bounds `by_sha` + `resolved` memory via
  `:max_resolved_bytes` so a pack of many small OFS_DELTA chains
  can't balloon heap beyond the per-pack cap (review #11/#35).
- **ObjectStore.Disk** `pread_tail/3` size-probes the pack file and
  reads the full object body instead of capping at 128 KiB. Objects
  larger than 128 KiB in packs now decode correctly; previously
  they silently returned truncated bodies (review #12).
- **Promisor.collect_commit_haves/1** uses a `:gb_trees` priority
  queue keyed on recency instead of sorting the full commit map.
  O(N log K) where N is the 256-cap, not O(K log K) per miss
  (review #32).
- **`Exgit.clone/2`** picks the default branch from the server's
  HEAD symref (via protocol-v2 `symrefs` on `ls-refs`) instead of
  guessing from advertised refs (review #9).
- **`Exgit.lazy_clone/2`** emits `[:exgit, :ref_store,
  :write_failed]` telemetry if a ref-store write fails during
  initial seed, instead of silently dropping the ref (review #8).
- **`Exgit.push/3`** emits an empty-but-valid PACK header when
  pushing a fast-forward that needs no new objects, matching git's
  `send-pack` wire shape; pure-delete pushes still send no pack
  (review #6).
- **RefStore.Disk.list_loose_refs/3** caps recursion depth at 16 and
  refuses to follow symlinks, defending against symlink loops in
  ref directories (review #36).
- **RefStore.Disk** parses peeled-tag lines in `packed-refs` instead
  of silently dropping them (review #37).
- **FS.resolve_tree/2** accepts a ref that points directly at a
  tree in both the string-ref and raw-SHA branches (review #40).
- **FS.resolve_tree/2** disambiguates 20-byte binary inputs: a
  binary of all printable ASCII with non-hex characters is treated
  as a ref name, not a SHA (review #41).
- **FS.compile_glob/1** returns a harmless always-false regex on
  compilation failure instead of raising (review #20).

### Security

- **CVE-worthy**: remote-controlled ref names can no longer escape
  the repo root via `Path.join`. `Exgit.RefName` validates every ref
  at the wire perimeter; `RefStore.Disk` re-validates defense-in-depth.
- **CVE-worthy**: hostile trees containing path-traversal entry
  names (`..`, `/foo`, `.git`) are rejected at `Tree.decode/1` —
  they never reach FS operations or a future checkout.
- **CVE-worthy**: a malformed commit (structurally valid but with
  non-hex `tree`/`parent` headers) previously DoS'd every operation
  that called a Commit accessor (walk, diff, push, FS). Validation
  moved into `decode/1`.
- **CVE-worthy**: credentials set via bare auth tuples are now
  host-bound automatically. Cross-origin redirects cannot leak the
  token regardless of Req's redirect behavior. Host matching is
  ASCII-case-folded and trailing-dot-stripped.
- Pack parser bounded at 2 GiB pack / 100 MiB per-object /
  500 MiB resolved-total by default; no hostile server response can
  unbounded-allocate the BEAM heap.
- `%Exgit.Credentials{}` has a custom `Inspect` impl that redacts
  auth values; crash logs, SASL reports, and IEx sessions do not
  leak tokens.
- Loose-object zlib decompression is wrapped in `try/rescue`;
  corrupt or tampered objects return tagged errors instead of
  crashing.

## [0.1.0] — 2026-04-17

Initial release: pure-Elixir git client for clone, fetch, push over
smart HTTP v2, with lazy partial-clone support and a path-oriented FS
API for agents.

See [README](./README.md) and [BENCHMARKS on the smoketest
repo](https://github.com/ivarvong/exgit_smoketest/blob/main/BENCHMARKS.md).
