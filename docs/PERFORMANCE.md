# Performance

How fast is exgit at what it's designed for — agent workflows that
lazy-clone a repo, prefetch the trees, and do many reads (grep,
read_path, walk)?

**Short answer:** on `anomalyco/opencode` (4,645 files, ~30 MB
fetch pack), a cold clone + prefetch completes in **~7 s** and
steady-state `grep` runs in **130–160 ms** for literal patterns
(Boyer-Moore) or **~335 ms** for case-insensitive regex. On the
436-file `adafruit/Adafruit_CircuitPython_Bundle`, steady-state
`grep` runs in **~2 ms**.

## TL;DR

| Fixture | Files | Fetch pack | Clone + prefetch | Grep (literal) | Grep (regex/ci) |
|---|---:|---:|---:|---:|---:|
| [`ivarvong/pyex`](https://github.com/ivarvong/pyex) | 275 | 1.2 MB | ~700 ms | ~11 ms | ~11 ms |
| [`cloudflare/agents`](https://github.com/cloudflare/agents) | 1,418 | 4 MB | ~8 s | ~58 ms | ~58 ms |
| [`anomalyco/opencode`](https://github.com/anomalyco/opencode) | 4,645 | ~30 MB | **~7 s** | **~140 ms** | **~335 ms** |
| [`adafruit/Adafruit_CircuitPython_Bundle`](https://github.com/adafruit/Adafruit_CircuitPython_Bundle) | 436 | ~1 MB | ~2 s | **~2 ms** | ~15 ms |

"Clone + prefetch" = `Exgit.clone(url, lazy: true)` +
`Exgit.FS.prefetch(repo, "HEAD", blobs: true)`.

"Grep (literal)" = case-sensitive, no regex metacharacters;
routes through `:binary.matches` (Boyer-Moore). "Grep (regex/ci)"
= case-insensitive `%Regex{}` scan.

Both grep numbers are steady-state (warm CPU, all objects in the
Memory store). The first grep after prefetch is the same cost —
unlike an older lazy-fetch path, prefetch now pre-populates
everything.

## What we measure

Four fixtures, each a real public GitHub repo. Picked to cover a
small-to-large size range with repos that have submodules, many
binary assets, and diverse layouts:

- `ivarvong/pyex` — **owned by the exgit maintainer**. Guaranteed
  against surprise force-push. Small (275 files), good for
  validating algorithmic baselines.
- `cloudflare/agents` — ~1.4k files. Medium real-world project.
- `anomalyco/opencode` — ~4.6k files, 26 MB blob in the pack. Large.
- `adafruit/Adafruit_CircuitPython_Bundle` — 436 files, uses git
  submodules (`.gitmodules` present). Previously crashed on prefetch
  due to an over-eager reserved-name check. Included as a regression
  fixture.

The benchmark harness (`bench/review_bench.exs`) does:

1. `Exgit.clone(url, lazy: true)` — refs only, no objects.
2. `Exgit.FS.prefetch(repo, "HEAD", blobs: true)` — stream the full
   blob pack directly into the Memory store via `Pack.StreamParser`.
3. **One "cold" grep** — steady-state (prefetch already populated everything).
4. **Five "warm" greps** — report the median.

## Benchmarks

All numbers are medians measured on a MacBook over a home internet
connection. `transport.fetch` varies 30–50% run-to-run due to
network; `pack.stream_parse`, `fs.grep`, and `fs.walk` are stable.

### anomalyco/opencode (4,645 files)

```
Phase                                    measured
--------------------------------------------------------------
clone(url, lazy: true)                   0.26 s
prefetch(blobs: true)                    6.4 s    ← streaming parser
grep "scd"             literal           158 ms
grep "TODO"            literal           130 ms
grep "useState"        literal           138 ms
grep "export default"  literal           132 ms
grep "anthropic"       regex/ci          333 ms
```

**Grep phase breakdown (4,645 blobs, 82 MB raw text):**

| Phase | Time | Share |
|---|---:|---:|
| Tree walk | 13 ms | 4% |
| `zlib.uncompress` × 4,645 blobs | 140 ms | 43% |
| Boyer-Moore scan (literal) | ~3 ms | 1% |
| PCRE scan (regex/ci) | ~150 ms | 46% |
| Line lookup + result alloc | ~15–65 ms | ~10% |

Literal patterns spend almost no time in the scan phase; the
bottleneck is `zlib.uncompress` in the Memory store. Case-insensitive
regex pays both the decompress and a slower PCRE scan.

### adafruit/Adafruit_CircuitPython_Bundle (436 files)

```
Phase                                    measured
--------------------------------------------------------------
clone(url, lazy: true)                   1.16 s
prefetch(blobs: true)                    0.65 s
grep "scd"             literal           2.2 ms   (14 hits)
grep "scd"             literal           2.5 ms
grep "scd"             literal           2.3 ms
```

436 files fit entirely in L3 cache after one prefetch pass;
Boyer-Moore through the full repo takes 2 ms and barely registers.

### Scaling

| Files | Grep / literal (ms) | Per-file (µs) |
|---:|---:|---:|
| 275 | 11 | 40 |
| 436 | 2 | 5 |
| 1,418 | 58 | 41 |
| 4,645 | 140 | 30 |

Per-file cost on opencode is **lower** than smaller repos because
its blobs are larger (more bytes compressed per file → fewer
`zlib.uncompress` calls relative to scan throughput); on adafruit
it is 5 µs because the compressed blobs stay warm in CPU cache
after the first grep.

## Architecture: end-to-end streaming pipeline

The biggest structural change since the original benchmarks is the
replacement of the buffered pack pipeline with a fully streaming
one. The old shape:

```
HTTP response → full binary in heap
              → Pack.Reader.parse (binary + resolved objects in heap simultaneously)
              → import_objects (another copy into the store)
```

Peak memory for opencode's 135 MB pack: ~400 MB (pack binary +
decoded object list + compressed store).

The new shape:

```
HTTP chunks → PktLine.Decoder → sideband demux
           → Pack.StreamParser.ingest/2 (one chunk at a time)
                ├── type/size header decode
                ├── zlib inflate port (open across ingest calls)
                ├── streaming deflate → ObjectStore directly
                └── OFS/REF delta resolved through store
           → StreamParser.finalize/1 (checksum verify)
```

Peak memory: one HTTP chunk (~4 KB) + one object's compressed
bytes in the write handle + the compressed store. The pack binary
never exists as a whole.

**opencode prefetch: 57 s → 6.4 s** — most of the 57 s was the
old Pack.Reader holding 135 MB of binary and the object list
simultaneously, triggering multiple major GC cycles. The streaming
parser never triggers that pressure.

### Adversarial hardening in the parser

`Pack.StreamParser.new/2` accepts limits enforced per-object
during the streaming parse:

```
max_object_bytes:   100 MB   — rejects before allocating
max_inflate_ratio:  1000×    — zip-bomb defence (compressed/raw ratio)
max_delta_depth:    50       — OFS/REF delta chain cap (same as git)
max_objects:        10 M     — rejects absurd pack headers
deadline:           nil      — monotonic cutoff; returns :deadline_exceeded
```

These fire during streaming, not as a post-parse check, so a
hostile pack stops consuming CPU/memory immediately.

## Grep: literal pattern fast path

`FS.grep/4` and `FS.multi_grep/4` detect case-sensitive literal
patterns (no PCRE metacharacters) at compile time and route them
through `:binary.matches` (Boyer-Moore-Horspool in the BEAM
runtime) instead of `Regex.scan`:

```elixir
# case-sensitive, no metacharacters → :binary.matches (9.5× faster)
FS.grep(repo, "HEAD", "useState")

# case-insensitive or metacharacters → Regex.scan
FS.grep(repo, "HEAD", "useState", case_insensitive: true)
FS.grep(repo, "HEAD", "use.*State")
```

Measured on 7.4 MB of synthetic text:

| Engine | Time | Speedup |
|---|---:|---:|
| `:binary.matches` (literal) | 8.6 ms | **1×** (baseline) |
| `Regex.scan` (literal regex) | 82 ms | 9.5× slower |
| `Regex.scan` (ci regex) | >10 s | >>100× slower at high hit density |

For typical code-search patterns (function names, import paths,
identifiers), the literal path is the default. Most agent queries
hit it without any caller changes.

## Parallelism: still a net loss

An earlier attempt parallelized `FS.grep` across blobs via
`Task.async_stream`. Result on opencode:

```
sequential (default):   340 ms
parallel (16 workers):  1550 ms   ← 4.5× SLOWER
```

The cause: `zlib.uncompress` is a regular (non-dirty) NIF. Running
16 concurrent calls each allocating large binaries simultaneously
causes severe GC pressure — 74 MB of heap allocation per grep in
16 processes simultaneously fragments memory and triggers
stop-the-world GC. The sequential path avoids this: each blob's
bytes are allocated, used, and collected before the next blob is
touched.

`max_concurrency: :schedulers` remains available for callers with
workloads where per-file work is substantial (large blobs, I/O-bound
stores). For typical code search on a Memory-backed repo, leave it
at the default of `1`.

## Bug fixes in this cycle

### `.gitmodules` blocked legitimate repos

`Tree.decode/1` was rejecting `.gitmodules` as a reserved entry
name, treating it the same as `.git` (CVE-2014-9390 class). The
comment even noted it was pre-emptive: "URL-injection vector for
submodule handling *if/when we add submodules*."

The consequence: any repo that uses git submodules — including
`adafruit/Adafruit_CircuitPython_Bundle` — crashed on prefetch
with `{:tree_entry_name_reserved, ".gitmodules"}`.

**Fix:** `.gitmodules` is now accepted. The URL-injection concern
only applies if we process submodule URLs, which exgit does not.
`.git` remains rejected (CVE-2014-9390 is real on case-insensitive
filesystems even for read-only clients).

### Earlier bugs (still in history)

Three compounding bugs in the original hot path documented here
for historical context (fixes landed in commit `550100d`):

1. **`FS.walk` discarded the updated repo** after `resolve_tree`,
   re-fetching the same commit from GitHub on every `walk` call.
   7.7s → 2 ms on cloudflare/agents.

2. **Promisor cache accounting counted decompressed bytes** while
   the store held compressed bytes; eviction fired 3–10× too early
   and dropped commits that were immediately needed. Fixed by
   tracking compressed sizes.

3. **`:max_resolved_bytes` default of 500 MiB** rejected
   opencode's ~524 MiB resolved set. Raised to 2 GiB.

## Optimizations that matter (shipped)

In order of impact:

1. **Streaming pack parser** (`Pack.StreamParser`) — replaces the
   buffered `Pack.Reader` in all fetch/prefetch paths. Eliminates
   the O(pack_size) binary + object list from the heap; bounded to
   one chunk + one object at a time. opencode prefetch: 57 s → 6 s.

2. **Streaming object-store writes** — `open_write/write_chunk/close_write`
   protocol on `ObjectStore`; Memory and Disk stores stream
   compressed output as inflate output arrives. Raw content never
   coexists with compressed form in the heap.

3. **Walk state threading** — updated repo threaded through the
   walk `Stream.resource` state, eliminating per-walk network
   fetches on lazy repos. 3,800× faster on cloudflare/agents.

4. **Literal grep fast path** — `:binary.matches` (Boyer-Moore)
   for case-sensitive literal patterns. 9.5× faster scan per blob;
   visible at adafruit scale (2 ms grep) and meaningful at opencode
   scale (dominant cost shifts to `zlib.uncompress`, not scan).

5. **Adler32 probe for pack zlib tracking** — finds the end of each
   zlib stream in O(1) instead of O(log N) binary-search probes.
   2.6× faster `Pack.Reader.parse` (still used for Disk store
   random-access lookups).

6. **Sequential grep as default** — avoids Task.async_stream GC
   pressure on typical workloads.

## What we're not doing

- **Decompressed-blob cache.** The 140 ms `zlib.uncompress` tax is
  paid on every grep call. A `repo.blob_cache: %{sha => binary}`
  field on the Repository struct, populated by a `FS.warm/2` call,
  would reduce repeated greps to near-zero. The design is correct
  (state on the struct, caller opts in, GC'd with the repo) but
  deferred until a measured workload asks for it. We explicitly
  ruled out ETS, Process dictionary, and persistent_term — any
  cache must be caller-visible and scoped to the repo value.

- **NIF-based zlib / libdeflate.** Would reduce `zlib.uncompress`
  cost 3–5×, making the 140 ms → ~30 ms. Undercuts the
  "pure Elixir, no NIFs" positioning; not doing this without a
  concrete workload and a clear tradeoff decision.

- **Parallel pack parsing.** OFS_DELTA chains impose a sequential
  dependency (base must precede delta in the forward walk). A
  two-pass design could unlock parallelism for the inflate phase;
  left for when a workload demonstrates the need.

- **Chunked parallel grep.** Per-task `Task.async_stream` at file
  granularity is net-negative (4.5× slower). A chunked variant
  batching 200–500 files per task would amortize spawn overhead and
  likely win on 10k+ file repos. Needs a measured workload.

## Running the benchmark yourself

```sh
# Clone + prefetch + grep workflow (all fixtures, 30 runs each)
mix run bench/review_bench.exs

# Filter to one fixture
mix run bench/review_bench.exs 10 opencode

# Local pack parse: StreamParser vs Pack.Reader head-to-head
# (requires local opencode .git pack files)
mix run bench/local_pack_eval.exs

# Pack parse scaling (synthetic, no network)
mix run bench/pack_parse_bench.exs

# Agent-session simulation: multi_grep + grep+context + blame + read_lines
mix run bench/agent_session_bench.exs
```

## Memory model summary

| Component | Bound |
|---|---|
| HTTP transport | One pkt-line per ingest chunk |
| Pack buffer | One object's compressed bytes |
| In-flight inflate | O(zlib_window) per chunk |
| Streaming write handle | O(compressed output chunks) |
| offset_to_sha map | ~35 bytes × N objects |
| sha_to_depth map | ~30 bytes × N objects |
| raw_cache (delta resolution) | 64 MB budget (plain map in StreamParser state) |
| Object store (Memory) | All objects compressed — inherent minimum |

The object store is the floor: if you fetch a 135 MB pack and store
it in a Memory backend, you'll hold however many bytes the compressed
objects take. Exgit does not add overhead on top of that minimum.

## Correctness oracle

`FS.grep` output is validated against `git grep` via
`test/exgit/fs_grep_git_parity_test.exs`. The test builds a small
real-git repo, runs both `git grep -n` and `Exgit.FS.grep` against
a set of representative patterns, and asserts the two agree on the
`(path, line_number)` match set. Tagged `:real_git` and `:slow`.

## History

See [`CHANGELOG.md`](../CHANGELOG.md) for the feature-level history.
Key perf commits:

- Streaming pack parser, streaming writes, literal grep, `.gitmodules` fix — current PR
- `550100d` — walk state threading; cache accounting fix; Adler32 probe
- `9bb1256` — partial clone haves bug fix
- `8678b0d` — initial Adler32 probe; code-quality gates
