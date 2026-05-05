# Load .env if present (dev/local). Real CI should inject these via
# secrets, so missing .env is not an error.
env_file = Path.join([__DIR__, "..", ".env"])

if File.exists?(env_file) do
  for line <- File.read!(env_file) |> String.split("\n", trim: true),
      not String.starts_with?(line, "#") do
    # Accept `FOO=bar` or `export FOO=bar`. Strip single/double quotes.
    case String.split(line, "=", parts: 2) do
      [k, v] ->
        key = k |> String.trim_leading("export ") |> String.trim()
        val = v |> String.trim() |> String.trim(~s(")) |> String.trim(~s('))
        System.put_env(key, val)

      _ ->
        :ok
    end
  end
end

exclude = []

exclude =
  if Exgit.Test.RealGit.available?() do
    exclude
  else
    [{:real_git, true} | exclude]
  end

exclude =
  if Exgit.Test.CloudflareArtifacts.available?() do
    exclude
  else
    [{:cloudflare, true} | exclude]
  end

# Live-network tiers are excluded by default; opt in via
# `mix test --include github_private` (or other tag names).
exclude =
  [
    {:network, true},
    {:slow, true},
    {:integration, true},
    {:cloudflare, true},
    {:github_private, true},
    {:github_private_write, true}
    | exclude
  ]
  |> Enum.uniq()

# vfs ships VFS.ConformanceCase under test/support, which isn't on the
# load path of consumers — only its own test env. Until vfs publishes
# the harness in lib/, load it directly from the dep so our
# `use VFS.ConformanceCase` works. Skip silently if the file is missing
# (e.g. Elixir 1.17 CI tier where :vfs doesn't resolve).
conformance = Path.join([__DIR__, "..", "deps", "vfs", "test", "support", "conformance_case.ex"])

if File.exists?(conformance) and Code.ensure_loaded?(VFS.Mountable) do
  Code.require_file(conformance)
end

ExUnit.start(exclude: exclude)
