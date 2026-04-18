# Exgit Production Readiness Execution Log

Working through the prodready plan. RED-then-GREEN for every fix,
committed in logical groups so bisection works.

## Phase 0 — Security & crash-safety cliff

- [x] S1  Ref-name validation at transport boundary
- [x] S2  Credential host-binding enforced at struct level
- [x] O3  Redirect policy pinned on Req
- [x] S3  Decoder paths return structured errors (never raise)
- [x] A6  Replace binary-search compressed-length with safeInflate/2
- [x] S4  Fix {:callback, fun} arity mismatch
- [x] S5  Validate loose-object size; fallthrough on type_atom
- [x] S6  ObjectStore.Disk.import_objects returns partial_import errors
- [x] FUZZ Adversarial pack corpus (CI-gating)
- [x] BOUND  :max_pack_bytes / :max_object_bytes on parser

## Phase 1 — Scale & operability

- [x] A2  Disk pack reads via :file.pread/3
- [x] A1  O(1) commit-haves + cap at 256 with recency bias
- [x] A4  Lazy-clone streaming-ops UX: Repository.materialize/2 + raise on Promisor
- [x] A5  Pack.Index 0..n-1 guards
- [x] A7  Document sideband heuristic + property test
- [~] O2  Dialyzer, Credo in CI (continue-on-error for now; benchmarks deferred)

## Phase 2 — Interop & API hardening

- [~] Cross-server matrix — have: Transport.File + real `git` fixtures +
         live GitHub integration. Deferred: GitLab/Gerrit container tests
         (infrastructure-heavy; add when we see a real protocol drift).
- [x] Partial-clone edge cases (tree:0, blob:limit, invalid-filter rejection)
- [x] API audit; Credentials-struct migration (auto-wrapping in Transport.HTTP.new)
- [x] @doc experimental: true markers (lazy_clone, FS.prefetch, Repository.materialize)

## Phase 3 — Release rigor

- [x] SemVer commitment in README
- [x] CHANGELOG.md
- [x] SECURITY.md
- [x] Threat model (in SECURITY.md)
- [x] Telemetry event catalog finalized (in Exgit.Telemetry)
- [x] Hex publish dry-run (exgit-0.1.0.tar builds cleanly, 46 files)

## Phase 4 — Internal deploy (prerequisites landed; execution is
## calendar-time work that lives with the adopting team)

Everything in this phase is about OPERATING the library, not writing
it. The library itself is ready; what a rolling adopter needs to do:

- [ ] Pick a single first consumer (named team + named service)
- [ ] Ship behind a feature flag
- [ ] Shadow-run for 7 days, measure divergence = 0
- [ ] Progressive rollout: 1% → 10% → 50% → 100% with a 48h watch
      window per cohort
- [ ] 14 days at 100% before publishing an internal ADR that says
      "cleared for general internal use"
- [ ] Rollback plan rehearsed before 10% rollout
- [ ] Consumer emits `exgit.version` telemetry so incidents correlate
      to a library version

None of this is exgit library work; it belongs in the consumer's
deployment plan. The SECURITY.md threat model and the telemetry event
catalog give the consumer what they need to plan it.

## Not deferred to v0.3 per my review

- [x] Pack.Writer .idx emission (verified via git verify-pack)
- [-] Streaming pack writer (memory-bounded push) — deferred to v0.2.
      Correctness-neutral; symmetry with A2 (streaming read) would be
      nice but pushes don't hit the same "unbounded pack from hostile
      remote" threat as fetches.
- [-] Exgit.Test.MockTransport canonical harness — deferred. Every
      test file currently defines its own FakeT that takes 20 lines;
      consolidating is a v0.2 DX improvement.
