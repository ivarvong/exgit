# exgit — notes for Claude

## Before every commit

Run these in order. CI runs all of them; catching failures locally is faster.

```sh
mix format
mix compile --warnings-as-errors
MIX_ENV=dev mix credo --strict
mix test --warnings-as-errors
```

CI also runs Dialyzer (`MIX_ENV=dev mix dialyzer`) but it's slow (~2 min
on a cold PLT). Skip it locally unless you touched a typespec or protocol.

## What CI checks (`.github/workflows/ci.yml`)

| Step | Command | Notes |
|---|---|---|
| Compile | `mix compile --warnings-as-errors` | Warnings are errors |
| **Format** | `mix format --check-formatted` | Formatter is non-negotiable |
| Unused deps | `mix deps.unlock --check-unused` | Run after adding/removing deps |
| **Credo** | `MIX_ENV=dev mix credo --strict` | Strict = all categories, no exceptions |
| Dialyzer | `MIX_ENV=dev mix dialyzer` | Slow; primary matrix only |
| Tests | `mix test --warnings-as-errors` | Warnings are errors here too |
| Extended | `mix test --warnings-as-errors --include slow --include real_git` | Includes real git binary tests |
| Integration | `mix test --warnings-as-errors --only integration` | Live network (pyex) — primary only |

## Common Credo traps

- **Alias ordering**: aliases must be alphabetical within a group.
  `Exgit.Object` before `Exgit.Pack`, `{Blob, Commit}` before `{Tree}`.
- **TODO comments**: Credo flags `# TODO` at design level. Use
  `# TODO(owner):` to suppress, or rephrase as `# follow-up:`.
- **Function complexity**: cyclomatic complexity cap is 12. Extract
  helpers if you get close — `do_fetch` hit 13 and needed splitting.
- **Unused aliases**: every `alias` in a file must be referenced.
  Test files are checked too.
- **Unused private functions**: dead helpers in test files trigger
  `--warnings-as-errors` in `mix test`.

## Architecture invariants (don't break these)

- **No hidden state**: no ETS, no Process dictionary, no persistent_term
  in the hot path. State lives on the struct the caller holds.
- **No disk in the agent path**: `Exgit.clone/2` (default) uses Memory
  stores. `File.*` calls belong only in `ObjectStore.Disk`, `RefStore.Disk`,
  `Config`, and `Index`.
- **No auth on public repos**: never pass a PAT/token to `Exgit.clone/2`
  for a public repo. Credential exposure for no benefit.
- **StreamParser is pure**: `ingest/2` and `finalize/1` are pure functions
  that return updated state. No side effects except writes through the
  `ObjectStore` protocol callbacks.
- **ObjectStore protocol**: `put/2` returns `{:ok, sha, new_store}` — always
  thread `new_store` forward. Same for `open_write/close_write`.

## Test tags

| Tag | Meaning |
|---|---|
| (none) | Runs in default `mix test` |
| `:slow` | Long-running; included in extended CI tier |
| `:real_git` | Requires `git` binary on PATH |
| `:integration` | Live network; primary CI only |
| `:github_private` | Requires secrets; push-to-main only |
| `:memory` | Memory regression guard; run with `--include memory` |
| `:git_cross_check` | Cross-checks against real git binary |
| `:network` | Live network; excluded by default |
