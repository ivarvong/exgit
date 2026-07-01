#!/usr/bin/env bash
#
# Consumer-install smoke test.
#
# Verifies that a *downstream* project can depend on the exgit package
# AS IT SHIPS TO HEX and actually use the public API end-to-end.
#
# Why this exists: the in-repo `mix test` suite runs with every dev/test
# dependency present, `test/support` on the load path, and the full
# source tree visible. It therefore CANNOT catch the two failure modes
# that only bite a real adopter:
#
#   1. A file the code needs is missing from the `files:` glob in mix.exs
#      (the package tarball is incomplete).
#   2. Code under `lib/` has a compile-time reference to a dev/test-only
#      or optional dependency (e.g. the optional `:vfs` defimpl, Bypass,
#      StreamData) that isn't present in a clean consumer build.
#
# To reproduce a true consumer, we build the package the way Hex does,
# extract ONLY the shipped files, and depend on that extracted directory
# from a throwaway project compiled in :prod — so no dev/test deps and no
# test/support reach the build. Then we exercise the advertised workflow:
# clone a public repo and read a file by path.
#
# Network: clones https://github.com/elixir-ai-tools/just_bash (public,
# unauthenticated — per the "no auth on public repos" invariant).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building the Hex package (files: glob only)"
rm -f exgit-*.tar
mix hex.build
PKG_TAR="$(ls exgit-*.tar | head -1)"

echo "==> Unpacking package contents ($PKG_TAR)"
# A Hex package tar contains: metadata.config, contents.tar.gz, CHECKSUM,
# VERSION. The shipped source files live inside contents.tar.gz.
tar -xf "$PKG_TAR" -C "$WORK"
mkdir -p "$WORK/pkg"
tar -xzf "$WORK/contents.tar.gz" -C "$WORK/pkg"
rm -f "$PKG_TAR"

echo "==> Files the consumer will see:"
(cd "$WORK/pkg" && find . -type f | sort | sed 's/^/      /')

echo "==> Scaffolding a throwaway consumer project"
CONSUMER="$WORK/consumer"
mkdir -p "$CONSUMER/lib"

cat > "$CONSUMER/mix.exs" <<EOF
defmodule ExgitConsumerSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :exgit_consumer_smoke,
      version: "0.0.0",
      elixir: "~> 1.17",
      # Depend on the EXTRACTED package, not the source tree — so only
      # the shipped files and prod deps are visible. This is the whole
      # point of the smoke test.
      deps: [{:exgit, path: "${WORK}/pkg"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF

cat > "$CONSUMER/lib/smoke.ex" <<'EOF'
defmodule ExgitConsumerSmoke do
  @moduledoc "Clone a public repo with exgit and read a file by path."

  @url "https://github.com/elixir-ai-tools/just_bash"

  def run do
    # Eager, unauthenticated full clone of a public repo.
    {:ok, repo} = Exgit.clone(@url)

    # Path-oriented read: returns {:ok, {mode, %Exgit.Object.Blob{}}, repo}.
    {:ok, {_mode, blob}, _repo} = Exgit.FS.read_path(repo, "HEAD", "README.md")
    data = blob.data

    if byte_size(data) == 0 do
      raise "README.md came back empty"
    end

    unless String.contains?(String.downcase(data), "bash") do
      raise "README.md content did not look like just_bash (no 'bash' found)"
    end

    IO.puts("OK: cloned just_bash, read README.md (#{byte_size(data)} bytes)")
  end
end
EOF

echo "==> Resolving deps + compiling consumer in :prod (warnings as errors)"
cd "$CONSUMER"
export MIX_ENV=prod
mix local.hex --force >/dev/null
mix local.rebar --force >/dev/null
mix deps.get
mix compile --warnings-as-errors

echo "==> Running the smoke (clones just_bash over the network)"
mix run -e 'ExgitConsumerSmoke.run()'
