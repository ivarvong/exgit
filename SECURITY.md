# Security Policy

## Supported versions

Exgit is in active pre-1.0 development. Security fixes are made
against `main`. No back-porting to older 0.x releases is currently
offered.

| Version | Supported |
|---------|:---------:|
| main    | ✅        |
| 0.1.x   | ✅        |
| < 0.1   | ❌        |

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Email `ivar@ivarvong.com` with:

- A description of the issue
- Exact steps to reproduce (a minimal test case is best)
- The affected version / commit
- Any known mitigations

You should receive an acknowledgement within 3 business days. We'll
work with you on a disclosure timeline — typically 30–90 days depending
on severity and complexity of the fix.

We request embargo until the fix is released.

## Threat model

Exgit is a git **client** library. The trust boundaries we enumerate
and defend:

| Boundary | Input | Defenses |
|----------|-------|----------|
| Remote server → client | `ls-refs` output, pack bytes, redirects | `Exgit.RefName` validates ref names at the wire perimeter; `RefStore.Disk` re-validates defense-in-depth on every read/resolve/write/delete (#1). `Exgit.Object.Tree.decode/1` validates each entry name against path-traversal rules — rejects `..`, `/`, NUL, `.git`/`.gitmodules` in any case (#2). `Exgit.Object.Commit.decode/1` and `Tag.decode/1` validate hex in header values so accessor calls (`Commit.tree/1`, `Commit.parents/1`, `Tag.object`) are infallible — a hostile remote cannot DoS a walk/diff/FS operation by shipping a structurally-valid commit with non-hex headers (#23). `Pack.Reader` bounds memory via `:max_pack_bytes` / `:max_object_bytes` / `:max_resolved_bytes` (#11/#35) and never raises on hostile input. Credentials are host-bound by default with ASCII-case-folding + trailing-dot-stripping normalization (#5); redirects are disabled unless explicitly opted-in. |
| User-supplied URL | Transport construction | No special validation — it's the caller's responsibility to avoid SSRF-class risks from user-controlled URLs. Host-bound credentials limit damage. |
| User-supplied credential | PATs, basic auth, callbacks | `%Exgit.Credentials{}` and `%Exgit.Transport.HTTP{}` both implement custom `Inspect` protocols that redact auth values. Crash logs, SASL reports, and IEx sessions do not leak tokens. |
| Local filesystem (Disk store) | Object/ref files on disk | SHA verification on read detects bit-rot and tampering. `:zlib.uncompress/1` is wrapped in `try/rescue` so corrupt loose objects return `{:error, :zlib_error}` instead of crashing the caller (#3). Ref-store `resolve_ref/2` re-validates symbolic targets read from disk so a `ref: ../../etc/passwd` file cannot escape the repo root (#1). |
| Local filesystem (config) | `.git/config` | `.git/config` is treated as **caller-controlled** input, not remote-controlled. `Config.parse/1` returns `{:ok, _} | {:error, _}` and never raises. Exgit does not fetch or persist config received over the wire. **If/when submodule support lands, `.gitmodules` URLs will be a remote-attacker surface** (`file://` / `ssh://git@evil/…;rm -rf` class) and will need separate validation; not currently present. |
| User-supplied pack for push | `Exgit.push/3` arguments | Caller-generated input is within the trust boundary for push. Note that `Exgit.push/3` reads objects from the local store, which may contain objects that came from a remote via an earlier clone/fetch — objects ingress through `Pack.Reader` which enforces the bounds above. A hostile pack cached earlier cannot trigger traversal at push time because tree entry names have already been validated at fetch-time decode. |

**Not defended**: the agent/caller can push arbitrary content to a
remote if it has a write-scoped credential. That's by design — our
job is to prevent a remote from attacking the client, not to sandbox
the caller.

## Regression corpus

The test suite includes explicit regression tests for each
CVE-worthy finding. Per review:

| Finding | Test file |
|---------|-----------|
| #1 Ref-store disk path escape | `test/exgit/security/ref_escape_test.exs` + `test/exgit/security/ref_store_disk_boundary_test.exs` |
| #2 Tree entry path traversal | `test/exgit/security/tree_entry_name_test.exs` |
| #3 Loose object zlib raise | `test/exgit/security/zlib_error_test.exs` + `test/exgit/security/loose_object_test.exs` |
| #4 Pack inflate desync | `test/exgit/pack/inflate_tracked_test.exs` |
| #5 Credential host confusion | `test/exgit/security/credential_host_normalization_test.exs` + `test/exgit/credentials_host_test.exs` |
| #23 Commit hex DoS | `test/exgit/security/malformed_hex_commit_test.exs` |
| #23 (Tag sibling) | `test/exgit/security/tag_malformed_hex_test.exs` |

Any future security fix MUST land with a regression test in
`test/exgit/security/` that would fail without the fix.

## Known advisories

None yet. This file will list them with CVE IDs when applicable.

## Dependency policy

- `req` — network client. Minimum version pinned to one with
  known-good cross-origin auth-stripping default. **Bumping Req's
  major version requires re-running the cross-origin leak test suite
  before merging.** (Our host-bound `%Exgit.Credentials{}` is the
  primary enforcement; Req's behavior is a belt-and-suspenders
  layer.)
- `telemetry` — BEAM-standard instrumentation. Low risk.
- `opentelemetry_*` — dev/test only; not present in production
  runtime.
- `stream_data`, `dialyxir`, `credo` — dev/test only.

A full SBOM is generated as part of the release process.

## Cryptography

Exgit uses `:crypto.hash(:sha, _)` for git object SHA-1s. SHA-1 is
**not collision-resistant** in the modern cryptographic sense, but git
itself relies on SHA-1 and so does exgit. If you are working with a
SHA-256 git repository (rare, opt-in at repo creation), exgit does
not yet support it (tracked as a v0.2+ item).

## Responsible disclosure

We follow [coordinated disclosure](https://en.wikipedia.org/wiki/Coordinated_vulnerability_disclosure).
Reporters are credited in the CHANGELOG unless they request anonymity.
