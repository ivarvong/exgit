# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- `:max_pack_bytes` (default 2 GiB) and `:max_object_bytes` (default
  100 MiB) options on `Exgit.Pack.Reader.parse/2` bound memory on
  untrusted input.
- `[:exgit, :security, :ref_rejected]` and
  `[:exgit, :object_store, :haves_sent]` telemetry events.
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

### Security

- **CVE-worthy**: remote-controlled ref names can no longer escape
  the repo root via `Path.join`. `Exgit.RefName` validates every ref
  before any filesystem touch.
- **CVE-worthy**: credentials set via bare auth tuples are now
  host-bound automatically. Cross-origin redirects cannot leak the
  token regardless of Req's redirect behavior.
- Pack parser bounded at 2 GiB by default; no hostile server response
  can unbounded-allocate the BEAM heap.

## [0.1.0] — 2026-04-17

Initial release: pure-Elixir git client for clone, fetch, push over
smart HTTP v2, with lazy partial-clone support and a path-oriented FS
API for agents.

See [README](./README.md) and [BENCHMARKS on the smoketest
repo](https://github.com/ivarvong/exgit_smoketest/blob/main/BENCHMARKS.md).
