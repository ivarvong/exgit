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

ExUnit.start(exclude: exclude)
