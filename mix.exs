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
      # CI matrix tests both 1.17 (minimum-supported) and 1.19
      # (primary + stricter type checks).
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer(),
      # Don't consolidate protocols in test so test-only implementations
      # (e.g. fake transports) load without a clean rebuild.
      consolidate_protocols: Mix.env() != :test,
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Mix CLI configuration. Lives in its own callback (per Mix 1.14+)
  # rather than in `def project` so that `:preferred_envs` doesn't
  # trigger a deprecation warning under Mix 1.19.
  def cli do
    [
      preferred_envs: [
        dialyzer: :dev,
        "bench.run": :test
      ]
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
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md SECURITY.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "SECURITY.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  def application do
    # Do NOT add :vfs (or any other optional integration) here. vfs is a
    # compile-time-optional integration: we use its protocol module via
    # `defimpl VFS.Mountable, for: Exgit.Workspace` when it is present,
    # but exgit must NOT declare :vfs as a runtime application — vfs
    # itself depends on exgit (in dev/test), and listing it here would
    # deadlock `:application_controller` at boot for any consumer that
    # bundles both libs. The corresponding `runtime: false` flag on the
    # :vfs entry in `deps/0` is what keeps Mix from auto-injecting it.
    [
      extra_applications: [:logger, :crypto],
      mod: {Exgit.Application, []}
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
      # Optional vfs integration: `Exgit.Workspace` ships a
      # `VFS.Mountable` defimpl when `:vfs` is loaded. Pinned to a SHA
      # because vfs has no hex release yet.
      #
      # `optional: true` means downstream consumers don't have to install
      # :vfs to use exgit; if they DO add :vfs, Mix orders our build after
      # vfs's so the defimpl compiles in and protocol consolidation picks
      # it up.
      #
      # `runtime: false` is load-bearing. Without it, Mix auto-includes
      # :vfs in exgit's generated `applications` list (optional deps are
      # still added as application edges; `optional_applications` only
      # tells `:application_controller` it's OK if the app is absent — it
      # does NOT break the dependency edge when present). vfs in turn
      # depends on exgit (for its own integration tests), so any build
      # that bundles both — e.g. an agent app pulling in both libs —
      # creates a cycle in `:application_controller` that deadlocks at
      # boot. We use vfs's protocol module at COMPILE time (to define
      # `defimpl VFS.Mountable, for: Exgit.Workspace`); there is no vfs
      # supervision tree we depend on at runtime, so `runtime: false` is
      # not a workaround — it's an accurate description of the
      # relationship. Same shape as Phoenix and its optional templating
      # adapters.
      #
      # We deliberately do NOT scope this to :dev/:test only — that would
      # remove vfs from our dep graph in :prod, breaking compile-ordering
      # guarantees in downstream consumer builds. Requires Elixir ~> 1.18;
      # the 1.17 CI tier skips the integration via `Code.ensure_loaded?`.
      {:vfs,
       github: "ivarvong/vfs",
       ref: "32d2ab618ec12c16fe4f675b5ee8b563c660dd69",
       optional: true,
       runtime: false},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      # Test-only: localhost HTTP server for stubbing the Cloudflare
      # Artifacts REST API in `test/exgit/cloudflare_artifacts_test.exs`.
      {:bypass, "~> 2.1", only: :test},
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
      # `:vfs` is `runtime: false` in deps/0 so it stays out of our
      # generated `applications` list (see comment on the :vfs dep for
      # why). Side effect: Dialyxir's default PLT closure follows
      # `applications`, so without this hint vfs's beams are absent
      # from the PLT and `lib/exgit/workspace/vfs.ex` lights up with
      # spurious `unknown_function` warnings for `VFS.Error.new/2`,
      # `VFS.Path.normalize/1`, etc. Adding it here adds the beams to
      # the PLT only — it does not reintroduce a runtime application
      # edge.
      plt_add_apps: [:vfs],
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end
end
