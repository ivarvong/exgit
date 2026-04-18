# Design notes

Scratch space for design thinking that isn't a production commit
yet. Each section captures enough detail that a future maintainer
(possibly me in six months) can pick up the work without having
to re-reason from scratch.

## LRU cache eviction

**Status:** Designed, not implemented. Deferred because no real
adopter has yet reported a memory-bound workload. See
[`docs/PERFORMANCE.md`](PERFORMANCE.md) "Memory management"
section for the current stance.

### Problem

`Exgit.ObjectStore.Promisor` caches objects fetched from the
transport. For long-running processes (agent daemons, CI
workers), the cache grows until the process dies. Today's
defenses:

- `:max_cache_bytes: :infinity` is the default (no eviction).
- When a cap IS set, a FIFO-by-commit evictor runs — drops the
  oldest commit when over cap.

The FIFO evictor has two real problems:

1. **Commit-only eviction is the wrong granularity.** A
   Promisor cache in a partial-clone workflow might hold 10k
   blobs and 2 commits. Dropping a commit doesn't reclaim
   meaningful memory; blobs+trees are 99% of the bytes.

2. **It evicts state streaming ops depend on.** If a `FS.walk`
   triggered a commit fetch mid-stream, and we also just
   triggered eviction due to a concurrent blob read pushing us
   over cap, the evictor can drop the commit we're actively
   walking. Broken.

### Proposed design

Access-time LRU over all object types, eviction-aware streams.

**Core data structures:**

```
Promisor struct gains:
  access_counter : non_neg_integer()    # monotonic, increments on every touch
  access_order   : :gb_trees.tree()     # counter -> sha
  sha_to_counter : %{binary() => non_neg_integer()}   # sha -> counter (for O(log K) re-touch)
```

**On every read (`Memory.get_object(cache, sha)` via a
profiler-like hook):**

```
new_counter = p.access_counter + 1
if sha in sha_to_counter:
    remove old counter from access_order
    insert new counter → sha
    update sha_to_counter
else:
    # First access — already in cache from a write; start tracking
    insert new counter → sha
    sha_to_counter[sha] = new_counter
```

**On eviction (triggered post-insert when over cap):**

```
while cache_bytes > cap and !active_reservations_block_progress:
    {oldest_counter, oldest_sha} = :gb_trees.take_smallest(access_order)
    if oldest_sha in active_reservations:
        # Skip — pinned by an active stream. Try next.
        re-insert at next counter slot (cheap; it's O(log K))
        continue
    drop from cache, remove from sha_to_counter
    decrement cache_bytes by compressed_size
```

**Active reservations (eviction-aware streaming):**

A streaming op (`FS.walk`, `FS.grep`) acquires a **reservation**
on the SHAs it's actively touching. The eviction loop skips
those. Reservations are released when the stream terminates.

One implementation option: an ETS set keyed on SHA, value = pid
of the reserving stream. `after` callback on the Stream.resource
deletes the reservation. Another option: pass an
`opaque_reservation_token()` that sits in the stream state and
is checked on every eviction probe.

### Complications

1. **Pure-value Promisor vs ETS reservations.** The Promisor is
   currently a pure value — two callers holding the same struct
   see the same cache. Adding ETS reservations breaks that
   purity. Two fixes:
   - Move reservations to `SharedPromisor` (already a
     GenServer). The pure `Promisor` stays pure and doesn't
     support eviction-aware streaming; callers who want both
     bounded memory AND streaming wrap in SharedPromisor.
   - Add an optional reservations-ETS field to Promisor that's
     opt-in; if unset, eviction doesn't check reservations.

2. **Access-counter bookkeeping on reads.** Memory.get_object
   currently has no post-read hook into the Promisor. Either:
   - Wrap `Memory.get_object` through a new
     `Promisor.cache_get` that updates access_order.
   - Use `:ets.update_counter/3` in a separate ETS table to
     track touches.

3. **Migration for existing callers.** A `:max_cache_bytes`
   value that worked yesterday (when eviction was commit-only
   and would rarely fire) might evict aggressively tomorrow
   (true LRU fires on blob reads). Document the behavior
   change as a breaking minor-version bump.

4. **Measurement story.** The Profiler already reports
   `peak_cache_bytes` from telemetry metadata. Add two new
   telemetry events:
     - `[:exgit, :object_store, :evicted]` — measurements:
       `%{bytes_freed, object_count}`; metadata:
       `%{reason :: :cap_exceeded | :manual, cache_bytes_after}`.
     - `[:exgit, :object_store, :reservation_blocked]` —
       fires when eviction skips a pinned sha.

### Testing

Property tests:

- **Invariant 1 (bounded):** After any sequence of puts and a
  maybe_evict, `cache_bytes <= max_cache_bytes`.
- **Invariant 2 (streaming safety):** Under eviction-aware
  mode, any sha a stream has reserved is still in cache when
  the stream reads it.
- **Invariant 3 (recency):** After a sequence of N reads,
  evicting 1 object drops an object that hasn't been read in
  at least M positions, where M ≥ cache_size − 1.

Benchmark tests:

- Agent-workload bench at a memory cap that's ~50% of
  unbounded peak. Compare session times: bounded should be
  within 2× of unbounded (some re-fetching is acceptable;
  thrashing is not).

### Effort estimate

- Core data structures + touch hook: ~100 LoC
- Eviction loop with reservation checks: ~50 LoC
- SharedPromisor integration: ~80 LoC
- Property + integration tests: ~200 LoC
- Migration + docs: ~50 LoC

Total: ~500 LoC + ~1 day of careful testing. Worth it when a
real workload needs it; not worth it speculatively.

## Decompressed-blob cache

**Status:** Designed, not implemented. Behind a planned
`:decompressed_cache_bytes` Promisor option (default 0 = off).

Today: `Memory.get_object(cache, sha)` does `:zlib.uncompress` on
every call. For grep-heavy workloads over the same repo, the
same blob gets decompressed dozens of times.

Straightforward to add: a second map inside `Memory` keyed on
sha, with an LRU (the LRU-cap story above applies here too).
First call decompresses and caches; subsequent calls return from
the decompressed map.

Tradeoff:
- **Size:** decompressed is typically 3-10× larger than compressed.
- **Latency:** zlib inflate is ~1-2 µs per KB; avoiding it saves
  real time for many-blob workloads but micro-optimizes if the
  dominant cost is regex.

Measure via Exgit.Profiler.profile against the agent workload
bench BEFORE implementing. If `object_store.get` dominates,
it's a win. If `fs.grep`'s per-file regex work dominates, the
decompressed cache is premature.

## Literal-string fast path in FS.grep

**Status:** Designed, not implemented.

Current: all patterns go through `Regex.compile!` and `Regex.scan`.
For plain literal strings (the agent case: "find 'auth_token'"),
`:binary.compile_pattern/1` + `:binary.matches/2` uses
Boyer-Moore in native code, typically 2-5× faster than regex.

Detection heuristic: pattern is a binary AND
`Regex.escape(pattern) == pattern` (no metacharacters). Fall
through to the regex path otherwise.

Location: `Exgit.FS.compile_grep_pattern/2` dispatches on
pattern type. Add a third case for literal strings.

Same measurement caveat as above: profile before committing
engineering effort.
