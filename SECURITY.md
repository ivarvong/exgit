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
| Remote server → client | `ls-refs` output, pack bytes, redirects | `Exgit.RefName` validates ref names; `Pack.Reader` bounds memory (`:max_pack_bytes` / `:max_object_bytes`) and never raises on hostile input; credentials are host-bound by default; redirects are disabled unless explicitly opted-in. |
| User-supplied URL | Transport construction | No special validation — it's the caller's responsibility to avoid SSRF-class risks from user-controlled URLs. Host-bound credentials limit damage. |
| User-supplied credential | PATs, basic auth, callbacks | `Inspect` redacts all auth values in struct output so crash logs don't leak tokens. |
| Local filesystem (Disk store) | Object/ref files on disk | SHA verification on read detects bit-rot and tampering. |
| User-supplied pack for push | `Exgit.push/3` arguments | Not a concern: caller-generated input is within the trust boundary. |

**Not defended**: the agent/caller can push arbitrary content to a
remote if it has a write-scoped credential. That's by design — our
job is to prevent a remote from attacking the client, not to sandbox
the caller.

## Known advisories

None yet. This file will list them with CVE IDs when applicable.

## Dependency policy

- `req` — network client. Minimum version pinned to one with
  known-good cross-origin auth-stripping default. **Bumping Req's
  major version requires re-running the cross-origin leak test suite
  before merging.**
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
