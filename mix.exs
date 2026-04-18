defmodule Exgit.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ivarvong/exgit"

  def project do
    [
      app: :exgit,
      version: @version,
      elixir: "~> 1.17",
      # The library doesn't use any 1.19-only features; pinning the
      # lower bound at 1.17 keeps it installable for older consumers.
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer(),
      preferred_cli_env: [
        dialyzer: :dev,
        "bench.run": :test
      ],
      # Don't consolidate protocols in test so test-only implementations
      # (e.g. fake transports) load without a clean rebuild.
      consolidate_protocols: Mix.env() != :test,
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  defp description do
    """
    Pure-Elixir git: clone, fetch, push over smart HTTP v2 with lazy
    partial-clone support and a path-oriented FS API for agents.
    No `git` binary, no libgit2, no shelling out.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      # Telemetry: BEAM-wide standard for instrumentation. Emits events
      # consumers can attach to. Zero cost when no handler is attached.
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      # Optional dev-only OpenTelemetry bridge: auto-converts :telemetry
      # events into OTel spans. Only loaded in dev/test; production users
      # can wire their own handlers.
      {:opentelemetry, "~> 1.5", only: [:dev, :test]},
      {:opentelemetry_api, "~> 1.4", only: [:dev, :test]},
      {:opentelemetry_telemetry, "~> 1.1", only: [:dev, :test]},
      {:opentelemetry_exporter, "~> 1.8", only: [:dev, :test]},
      # Dev-only static analysis. Not runtime deps.
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev], runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts/core",
      plt_local_path: "priv/plts/project",
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end
end
