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

- [ ] A2  Disk pack reads via :file.pread/3
- [ ] A1  O(1) commit-haves + cap at 256 with recency bias
- [ ] A4  Lazy-clone streaming-ops UX: Repository.materialize/2 + raise on Promisor
- [ ] A5  Pack.Index 0..n-1 guards
- [ ] A7  Document sideband heuristic + property test
- [ ] O2  Dialyzer, Credo, benchmarks in CI

## Phase 2 — Interop & API hardening

- [ ] Cross-server matrix (local fixtures via real-git)
- [ ] Partial-clone edge cases
- [ ] API audit; Credentials-struct migration
- [ ] @doc experimental: true markers

## Phase 3 — Release rigor

- [ ] SemVer commitment in README
- [ ] CHANGELOG.md
- [ ] SECURITY.md
- [ ] Threat model
- [ ] Telemetry event catalog finalized
- [ ] Hex publish dry-run

## Not deferred to v0.3 per my review

- [ ] Pack.Writer .idx emission
- [ ] Streaming pack writer (memory-bounded push)
- [ ] Exgit.Test.MockTransport canonical harness
