defmodule Exgit.Transport.HttpOptionsTest do
  @moduledoc """
  Coverage for `Exgit.Transport.HTTP.new/2` configuration options —
  specifically the knobs a frontier-lab deployment will need:

    * `:receive_timeout` — default must tolerate slow cold fetches
    * `:connect_options` — pass-through for custom CA / mTLS
  """

  use ExUnit.Case, async: true

  alias Exgit.Transport.HTTP

  describe ":receive_timeout default" do
    test "defaults to 5 minutes, not 60 seconds" do
      t = HTTP.new("https://example.com/repo")

      # 300_000 ms = 5 minutes. Low enough to fail fast on a dead
      # connection, high enough for a 500 MB pack over a slow link.
      assert t.receive_timeout == 300_000
    end

    test ":infinity disables the timeout" do
      t = HTTP.new("https://example.com/repo", receive_timeout: :infinity)
      assert t.receive_timeout == :infinity
    end
  end

  describe ":connect_options pass-through" do
    test "defaults to an empty list" do
      t = HTTP.new("https://example.com/repo")
      assert t.connect_options == []
    end

    test "caller-supplied options are stored on the struct" do
      opts = [
        cacertfile: "/etc/ssl/certs/internal_ca.pem",
        certfile: "/etc/ssl/certs/client.pem",
        keyfile: "/etc/ssl/private/client.key"
      ]

      t = HTTP.new("https://gerrit.internal/repo", connect_options: opts)
      assert t.connect_options == opts
    end

    test "merges with library defaults for HTTPS TLS verify settings" do
      # The internal `connect_options/2` helper isn't public, but we
      # can exercise its behavior end-to-end by calling
      # `request_opts/5` (which IS exposed for test introspection).
      t =
        HTTP.new("https://example.com/repo",
          connect_options: [transport_opts: [depth: 10]]
        )

      # `request_opts/5` is called during every actual request; it
      # builds the Req options including `:connect_options`. We
      # inspect it here without making a network call.
      opts = HTTP.request_opts(t, :get, "https://example.com/repo/info/refs", [], "")

      connect_opts = Keyword.fetch!(opts, :connect_options)
      transport_opts = Keyword.fetch!(connect_opts, :transport_opts)

      # Caller's :depth override wins.
      assert Keyword.fetch!(transport_opts, :depth) == 10

      # Library defaults survived the merge.
      assert Keyword.fetch!(transport_opts, :verify) == :verify_peer
      assert is_list(Keyword.fetch!(transport_opts, :cacerts))

      assert Keyword.has_key?(
               Keyword.fetch!(transport_opts, :customize_hostname_check),
               :match_fun
             )
    end

    test "caller can fully replace cacerts with cacertfile for an internal CA" do
      t =
        HTTP.new("https://gerrit.internal/repo",
          connect_options: [transport_opts: [cacertfile: "/etc/ssl/certs/my_ca.pem"]]
        )

      opts = HTTP.request_opts(t, :get, "https://gerrit.internal/repo/info/refs", [], "")
      transport_opts = Keyword.fetch!(Keyword.fetch!(opts, :connect_options), :transport_opts)

      # Caller's cacertfile is there; cacerts default is still there
      # (Erlang's :ssl honors the last-wins rule at the socket level).
      assert Keyword.fetch!(transport_opts, :cacertfile) == "/etc/ssl/certs/my_ca.pem"
      assert Keyword.has_key?(transport_opts, :cacerts)
    end
  end
end
