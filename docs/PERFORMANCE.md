# Performance

How fast is exgit at what it's designed for — agent workflows that
lazy-clone a repo, prefetch the trees, and do many reads (grep,
read_path, walk)?

**Short answer:** on `ivarvong/pyex` (275 files, 1.2 MB pack),
steady-state `grep` runs in 11 ms. On `anomalyco/opencode` (4,600
files, ~30 MB pack), steady-state `grep` runs in 451 ms (~97 µs
per file). Scaling is near-linear in file count.

This document describes what the numbers are, how we measured
them, and what we broke + fixed in order to make them honest.

## TL;DR

| Fixture | Files | Pack | Warm grep (median) | Per-file |
|---|---:|---:|---:|---:|
| [`ivarvong/pyex`](https://github.com/ivarvong/pyex) | 275 | 1.2 MB | **11 ms** | 40 µs |
| [`anthropics/claude-agent-sdk-python`](https://github.com/anthropics/claude-agent-sdk-python) | 96 | ~1 MB | **6.8 ms** | 71 µs |
| [`cloudflare/agents`](https://github.com/cloudflare/agents) | 1,418 | 4 MB | **58 ms** | 41 µs |
| [`anomalyco/opencode`](https://github.com/anomalyco/opencode) | 4,600 | ~30 MB | **451 ms** | 98 µs |

"Warm grep" = steady-state `Exgit.FS.grep/4` against a repo whose
cache has already absorbed the first on-demand commit fetch. This
is the number that matters for an agent loop doing many searches
against the same repo; the first call pays a one-time ~50-500 ms
tax for the commit fetch, everything after it is local.

Full numbers including the full `clone → prefetch → grep` workflow
are in the **[Benchmarks](#benchmarks)** section.

## What we measure

Three fixtures, each a real public GitHub repo. Picked to cover a
small-to-large size range with **different ownership models** so
the benchmark is reproducible without depending on any single
maintainer's choices:

- `ivarvong/pyex` — **owned by the exgit maintainer**. Guaranteed
  against surprise force-push / rename. Small (275 files).
- `cloudflare/agents` — Cloudflare org repo. ~1.4k files. Medium
  real-world project, representative of many production codebases.
- `anomalyco/opencode` — Anomaly org repo. ~4.6k files. Large,
  used for grep-at-scale validation.

The benchmark harness (`bench/review_bench.exs`) does:

1. `Exgit.clone(url, lazy: true)` — refs only, no objects.
2. `Exgit.FS.prefetch(repo, "HEAD", blobs: true)` — fetch every
   reachable tree and blob in one pack.
3. **One "cold" grep** — triggers the commit-object on-demand fetch.
4. **Five "warm" greps** — steady-state measurement; all cache hits
   except possibly the first. We report the median.

Runs are preceded by a warm-up iteration (discarded) so TLS
session resumption and TCP connection-pool setup don't contaminate
the timings.

Every call site emits `:telemetry` span events, so the harness also
reports per-event medians independently of the wall-clock phase
timings.

## Benchmarks

All numbers below are medians over multiple runs from my MacBook to
GitHub's public API, on a home internet connection. Network is the
biggest source of variance — the same benchmark run an hour later
can differ by 30-50% in `transport.fetch`. Steady-state
cache-bound operations (`fs.walk`, `fs.grep`, `pack.parse`) are
rock-solid stable run to run.

### pyex (275 files, 1.2 MB pack)

```
Phase                                    median         p95
--------------------------------------------------------------
1. clone(url, lazy: true)               51.5 ms     58.5 ms
2. prefetch(blobs: true)               633.0 ms    655.3 ms
3a. grep (first / cold)                 11.0 ms     11.3 ms
3b. grep (warm, median of 5)            10.7 ms     11.2 ms
   total (1 + 2 + 3a)                  702.5 ms    717.8 ms

Telemetry medians
-----------------
transport.ls_refs    51.4 ms
transport.fetch     342.1 ms
pack.parse           48.3 ms
fs.walk              10.9 ms
fs.grep              10.9 ms
object_store.get     85 µs
```

### cloudflare/agents (1,418 files, ~4 MB pack)

```
Phase                                    median         p95
--------------------------------------------------------------
1. clone(url, lazy: true)               73.5 ms     75.3 ms
2. prefetch(blobs: true)                 8.19 s      8.51 s
3a. grep (first / cold)                 56.4 ms     58.2 ms
3b. grep (warm, median of 5)            58.4 ms     60.9 ms
   total (1 + 2 + 3a)                    8.32 s      8.63 s

Telemetry medians
-----------------
transport.ls_refs    71.7 ms
transport.fetch       2.63 s       (8 MB pack + TLS + GitHub)
pack.parse          680.0 ms       (~1.2 MB/s decompress+verify)
fs.walk              58.2 ms
fs.grep              58.2 ms
object_store.get    184 µs
```

### anomalyco/opencode (4,600 files, ~30 MB pack)

```
Phase                                    median
--------------------------------------------------------------
1. clone(url, lazy: true)              270.3 ms
2. prefetch(blobs: true)                57.39 s
3a. grep (first / cold)                420.5 ms
3b. grep (warm, median of 5)           451.3 ms
   total (1 + 2 + 3a)                   58.09 s

Telemetry medians
-----------------
transport.ls_refs   267.3 ms
transport.fetch      28.24 s       (30 MB pack)
pack.parse            6.52 s       (~4.6 MB/s decompress+verify)
fs.walk             451.1 ms
fs.grep             451.1 ms
object_store.get    678 µs
```

### Scaling

Grep time versus file count across fixtures:

| Files | Grep (ms) | Per-file (µs) |
|---:|---:|---:|
| 275 | 11 | 40 |
| 1,418 | 58 | 41 |
| 4,600 | 451 | 98 |

Near-linear up to ~1.5k files, with a step up at opencode scale.
The step is binary-content detection (the NUL-byte scan on the
first 8 KB of each file) showing up in the mix — opencode has
more binary assets than the other two. Real code searches would
typically pass a `:path` glob (`"**/*.ex"`) to filter upfront,
which drops per-file cost.

## What it takes to get there

The numbers above aren't where we started. Three bugs in the core
hot path compounded silently, each hiding behind the next:

### Bug 1: `FS.walk` discarded the updated repo after `resolve_tree`

```elixir
# The bug:
case resolve_tree(repo, reference) do
  {:ok, sha, _repo} -> [{"", sha}]   # _repo with the grown cache, discarded
  _ -> []
end
```

`resolve_tree` does an on-demand commit fetch for a lazy repo.
The commit is cached, but we pattern-matched `_repo` and threw it
away. Every call to `FS.walk` on a lazy repo whose commit wasn't
already cached triggered a fresh network round-trip.

**Observed:** On `cloudflare/agents`, each `FS.walk` took **7.7
seconds**. Not 7.7 ms — seconds. Because every walk re-fetched the
same commit from GitHub, every time.

Nobody noticed because the offline test suite used a `Memory`
object store where `resolve_tree` never fetched anything. The bug
only manifested against a real lazy `Promisor`-backed repo, and
we didn't have integration tests for partial-clone workflows. The
bug was discovered when we added real-world fixtures to the
benchmark.

**Fix:** thread the updated repo through the `Stream.resource`
state tuple as `{repo, stack}`. Now the grown cache is captured
for the full lifetime of the stream.

**Impact:** `FS.walk` on `cloudflare/agents`: 7.7s → **2 ms**.
That's 3,800× faster.

### Bug 2: Promisor cache accounting counted decompressed bytes

`Promisor.fetch_and_cache/2` was doing:

```elixir
new_bytes = Enum.sum(for {_t, _s, c} <- parsed, do: byte_size(c))
```

But `c` is the **decompressed** object content. The Memory store
actually holds compressed bytes. Accounting was off by 3-10×
depending on content entropy.

Combined with a previous 64 MiB default for `:max_cache_bytes`,
this meant eviction fired on every real-world prefetch. Worse:
the evictor only evicts **commits** — and when the cache was
"overfull" during a walk, the evictor would drop the single
commit we'd just fetched to make the walk work. Walk broke
mid-stream.

**Fix:** two changes:

1. Track compressed-byte sizes via `compressed_size/2` and
   `sum_compressed_bytes/2`. The number now reflects actual
   memory consumption.
2. Change `:max_cache_bytes` default to `:infinity`. Unbounded
   is the right default for partial-clone / prefetch workflows:
   callers prefetch a known working set and want it to stay in
   memory. Callers with an actual memory envelope (long-running
   daemon, low-memory deployment) set a cap based on their budget.

The library's job is to give accurate metrics when asked. It is
not the library's job to guess a cap that's wrong for every user.

### Bug 3: `:max_resolved_bytes` default of 500 MiB blocked real repos

The pack reader has a cap on total resolved-object bytes —
protection against a hostile pack that compresses tightly but
expands to gigabytes. The default was 500 MiB; a guess, not a
measurement.

`anomalyco/opencode` resolves to ~524 MiB, just over the cap.
First time anyone tried to clone it with partial clone, the
parser rejected the pack.

**Fix:** raise default to 2 GiB (matches `:max_pack_bytes`). A
hostile pack that compresses to 2 GiB AND expands past 2 GiB
would still be caught, but at that scale the attacker needs >2
GiB of outgoing bandwidth and a pathological delta chain. Real
monorepos are now trivially accommodated.

### Optimization: Adler32 trailer probe for zlib tracking

Separately from the bugs, there's a real perf win in how we find
the end of each zlib stream in a pack. Packs concatenate zlib
streams with no explicit length prefix, so the parser has to
figure out where each stream ends.

Original implementation: binary-search over prefix lengths,
opening a fresh zlib stream at each probe. `O(log N)` port
round-trips per object, each allocating a full decompressed
result. Expensive at Linux-kernel scale.

New implementation: **Adler32 probe**. A zlib stream ends with a
4-byte big-endian Adler32 of the decompressed content. After we
decompress the object, we compute the checksum ourselves in BEAM
(~nanoseconds), then `:binary.match` for the 4-byte trailer in
the input. One pass, one verify. False-positive rate (the
checksum bytes coincidentally appearing in the deflate body) is
~1/2^32 per position; we verify with a single `inflateEnd` probe
and fall back to the binary search if the probe fails.

**Impact:** `Pack.Reader.parse` went from 127 ms → 49 ms on pyex
(2.6× faster). At opencode scale (~30 MB pack), it saves several
seconds per clone.

### Anti-optimization: parallel grep (reverted)

An initial attempt parallelized `FS.grep` across files via
`Task.async_stream`. It was **22× slower** on `cloudflare/agents`.

Per-file work in grep is microseconds of regex scan on ~10 KB of
code. `Task.async_stream`'s per-item spawn + message-passing
overhead is ~50-100 µs. For a 1.4k-file repo, parallel dispatch
paid 100 ms of overhead to save microseconds of work.

Parallelism IS a win when per-file work is substantial (large
blobs, complex regex, I/O-bound store). Callers with that
profile opt in via `Exgit.FS.grep(repo, ref, pattern,
max_concurrency: :schedulers)`. The default stays sequential.

## Optimizations that matter

A summary of the perf wins that are live, in order of impact:

1. **Adler32 probe for pack zlib tracking** — 2.6× faster `pack.parse`.
2. **Single-pass grep (`matches_in` rewrite)** — 13× faster `grep`
   on a repo with few matches (common case). Scan the whole blob
   for matches once; compute line numbers only for matches.
3. **Walk state threading** — eliminates per-walk network fetches.
   3,800× faster on a 1.4k-file lazy repo.
4. **Sequential grep as default** — avoids Task.async_stream
   overhead on typical code-search workloads.
5. **Unbounded cache default** — removes artificial cap that
   previously fired during normal prefetch.

## What we're not doing

- **NIF-based zlib**. `:zlib` is a port, which costs round-trips.
  A NIF via libdeflate would be ~3-5× faster on `pack.parse`.
  Undercuts the "pure Elixir, no shelling out, no NIFs"
  positioning; not doing this without a very clear reason.
- **Parallel pack parsing**. Pack parsing has a sequential
  dependency (OFS_DELTA chains reference earlier objects by
  offset), so parallelizing the decode itself requires a
  two-pass design. Worth doing when we see a real workload that
  needs it.
- **Index (`.git/index`) caching**. Currently `FS.walk` re-walks
  the tree on every call. Building an index-style path→sha map
  once per ref and reusing would halve some workloads. Revisit
  when profiling says it matters.

## Running the benchmark yourself

```
# Startup-cost bench: clone + prefetch + one grep
mix run bench/review_bench.exs

# Agent-workload bench: realistic mixed ls/grep/read session
mix run bench/agent_workload.exs

# Just pyex, 10 runs on either bench
mix run bench/review_bench.exs 10 pyex
mix run bench/agent_workload.exs 5 pyex hot

# Pack-parse scaling bench (synthetic, offline)
mix run bench/pack_parse_bench.exs
```

Harnesses live in `bench/`. They emit full per-phase and
per-event numbers so you can see exactly where time is going for
your network / workload.

## Instrumentation

Two new APIs for profiling and memory telemetry:

### `Exgit.Profiler`

Structured trace of every `:telemetry` span emitted during a
function call. Use for ad-hoc "where did time go?" questions
without adding print statements or building a handler.

```elixir
{result, profile} =
  Exgit.Profiler.profile(fn ->
    {:ok, repo} = Exgit.clone(url, lazy: true)
    {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
    Exgit.FS.grep(repo, "HEAD", "foo") |> Enum.to_list()
  end)

profile.total_us          # wall-clock in microseconds
profile.peak_cache_bytes  # observed peak memory
profile.totals            # %{"fs.grep" => %{count: 1, us: 11_000}, ...}
profile.events            # full ordered event list for drill-down
```

Attach once and read periodically for long-running processes:

```elixir
{:ok, handle} = Exgit.Profiler.attach()
# ... do work ...
profile = Exgit.Profiler.read(handle)
Exgit.Profiler.detach(handle)
```

### `Exgit.Repository.memory_report/1`

Structured memory report for a repo. Call between operations to
track peak memory, detect unexpected cache growth, or alert when
a configured cap is approached.

```elixir
Exgit.Repository.memory_report(repo)
# => %{
#   object_count: 17_500,
#   cache_bytes: 4_213_780,
#   commit_count: 122,
#   tree_count: 8_290,
#   blob_count: 9_210,
#   tag_count: 0,
#   max_cache_bytes: :infinity,
#   mode: :lazy,
#   backend: Exgit.ObjectStore.Promisor
# }
```

Consistent shape across all object-store backends. Suitable for
emission into observability stacks (Prometheus, Datadog, etc.)
without downstream branching on backend type.

## Correctness oracle

`Exgit.FS.grep` output is validated against `git grep` via
`test/exgit/fs_grep_git_parity_test.exs`. The test builds a small
real-git repo, runs both `git grep -n` and `Exgit.FS.grep` against
a set of representative patterns, and asserts the two agree on
the `(path, line_number)` match set.

Tagged `:real_git` (requires `git` on PATH) and `:slow` (runs 20+
pattern variants). Part of the extended-tier CI run that gates
every push.

Today's coverage: 7 patterns against 5 synthetic files. Expanding
the corpus is future work; the current set catches regressions in
line-number computation, regex semantics, and binary-file
skipping — the classes of bug most likely to land silently.

## What's next

The measurement infrastructure is in place; optimization choices
from here should be **data-driven** — profile a real agent
workload against real fixtures, find the hotspot, optimize.
Everything below is waiting on a concrete workload telling us
what matters.

### Candidate optimizations, not-yet-done

- **Decompressed-blob cache.** Memory.get_object currently does
  `:zlib.uncompress` on every call. For grep-heavy workloads
  against the same repo, caching the decompressed bytes would
  halve grep time. Costs memory (~3-5× per blob). Behind a flag.

- **Literal-string fast path for grep.** Current `FS.grep`
  compiles string patterns to `%Regex{}`. For literal patterns,
  `:binary.match` (Boyer-Moore in the runtime) is 2-5× faster.
  Detect via: pattern is a plain binary AND doesn't contain
  regex metacharacters.

- **Chunked parallel grep.** Per-file Task.async_stream was 22×
  SLOWER than sequential (per-item spawn overhead dominates
  microsecond regex work). A **chunked** version (batch 100-500
  files per task) would amortize the overhead and likely win on
  4k+ file repos. Needs the agent workload bench to confirm.

- **Path → sha index.** `FS.walk` re-walks the tree on every
  call. A one-time path→sha map built at prefetch would make
  `read_path` O(1) instead of O(depth). Low priority — tree
  walks are microseconds today.

### Memory management — deferred

A proper **LRU eviction** (access-time tracking, evicts
blobs/trees/commits by age, eviction-aware streaming) is
designed but not implemented. Current stance:

- `:max_cache_bytes: :infinity` is the default.
- `cache_bytes` is tracked accurately (compressed bytes).
- `Exgit.Repository.memory_report/1` lets operators monitor.

The LRU design is documented in [`docs/NOTES.md`](NOTES.md)
for the future maintainer who hits a memory-bound workload.
We'd rather build it against real usage constraints than
guess.

### Agent primitives

Three shipped in the Round 1 push:

- **`FS.read_lines(repo, ref, path, line_range)`** — read only the
  requested line range of a file. One decompress, bounded-work
  slicing. Measured against `git show REF:path | sed -n 'L1,L2p'`
  for parity. See commit `70627bc`.

- **`FS.grep` with `:context` / `:before` / `:after`** — N lines of
  surrounding context per match, `git grep -C N` parity. See
  commit `7659c7f`. Benchmark results below.

- **`FS.read_path(..., resolve_lfs_pointers: true)`** — detects
  git-lfs pointer blobs and surfaces them as
  `{:lfs_pointer, %{oid, size, raw}}` instead of silently
  returning the ~130 bytes of pointer text. Byte-parity tested
  against `git lfs pointer --check`. See commit `e5d3be2`.

Pending:

- **`FS.multi_grep(patterns)`** — N patterns in one walk.
- **`Exgit.Blame`** — last-writer-per-line. The single most
  commonly-requested missing feature.

### Benchmark: grep+context vs. grep+N×read_path

The killer use case for `:context` is "find a match and show it
with surrounding code." Before the flag shipped, an agent did
that with a grep followed by N `read_path` calls (plus line
splitting on the client). Now it's one call.

Measured via `bench/grep_context_bench.exs` against four real
fixtures, 5 runs each, median reported. Legacy = grep + up to 20
read_path + manual line slicing. New = `grep(context: 3)` capped
at 20 hits. Both produce equivalent output.

| Fixture | Files | Hits | Legacy (median) | New (median) | Speedup |
|---|---:|---:|---:|---:|---:|
| `ivarvong/pyex` | 275 | 2 | 9.1 ms | 8.7 ms | **1.04×** |
| `anthropics/claude-agent-sdk-python` | ~100 | 20 | 1.8 ms | 1.4 ms | **1.30×** |
| `cloudflare/agents` | 1,418 | 20 | 1.1 ms | 171 µs | **6.49×** |
| `anomalyco/opencode` | 4,600 | 20 | 1.5 ms | 280 µs | **5.47×** |

Why the spread:

- **pyex, 1.04×** — only 2 matches, so legacy does just 2
  `read_path` calls. The overhead being saved is small; most of
  the 9 ms is the grep itself scanning 275 files.
- **claude-agent-sdk-python, 1.30×** — 20 matches but small files
  (avg ~270 lines). Per-file decompress savings modest. Breakdown
  from a separate profile: grep 711 µs, 20× read_path 855 µs,
  grep+context 1305 µs. The "new way" adds ~600 µs of per-match
  context slicing (30 µs × 20), which eats most of the saved
  read_path time on small files.
- **cloudflare/agents, 6.49×** and **opencode, 5.47×** — larger
  files + hits scattered across the tree means legacy pays
  full-blob decompress + tree-walk overhead 20 times. New way
  does one walk + context slice per match.

The win scales with the **aggregate decompressed bytes avoided**,
not with file count. On small repos with tiny files, grep+context
is a small improvement (~1.0-1.3×). On real-world repos with
larger files and many matches, it's 5-7× — firmly in "this
changes agent latency" territory.

Invocation:

```
mix run bench/grep_context_bench.exs               # all fixtures, 5 runs
mix run bench/grep_context_bench.exs 10 agents     # 10 runs, agents only
```

## Known caveats

- `transport.fetch` is dominated by GitHub's side + HTTPS setup +
  raw pack bytes over your uplink. Numbers above are from a home
  residential connection. Datacenter-to-GitHub would be 2-5×
  faster. VPNs / corporate proxies can be much slower.
- Cold-cache performance on the first call after `clone(lazy: true)`
  includes an on-demand commit fetch (~50-500 ms depending on
  repo). All numbers reported here are steady-state unless
  labeled "cold."
- Binary file detection (`binary_content?/1`) runs on every blob
  during grep; it's cheap (8 KB NUL scan) but scales linearly with
  file count. A `:path` glob short-circuits this for files that
  don't match the glob.

## History

See [`CHANGELOG.md`](../CHANGELOG.md) for the feature-level
history. The perf work documented above landed in commits:

- `550100d` — FS.walk state threading; cache accounting fix; `:max_resolved_bytes` default raise; Adler32 probe.
- `9bb1256` — Partial clone haves bug fix (a different class of bug that was also silently killing the read path).
- `8678b0d` — Initial Adler32 probe work; code-quality gates.

None of this would have surfaced without real-world fixtures. The
pre-review baseline benchmark ran only against `ivarvong/pyex`,
which is small enough that all three bugs were invisible at its
scale. Adding `cloudflare/agents` and `anomalyco/opencode` as
fixtures was the highest-leverage change we made to the
benchmark suite.
