defmodule Exgit.Security.CredentialEnforcementTest do
  @moduledoc """
  Credential host-binding must be enforced by Transport.HTTP itself,
  not by caller convention. A %Credentials{} struct bound to host X
  must never send auth headers to a URL whose host is not X.

  Plus: on-wire redirect policy is pinned (redirect: false) so we
  don't depend on Req's default cross-origin auth-stripping behavior.
  """
  use ExUnit.Case, async: true

  alias Exgit.{Credentials, Transport}

  describe "Transport.HTTP.new/2 accepts a Credentials struct" do
    test "bound credentials attach auth when URL host matches" do
      cred = Credentials.host_bound("github.com", {:bearer, "secret"})
      t = Transport.HTTP.new("https://github.com/user/repo", auth: cred)

      # Internal inspection: call auth_headers_for/2 helper exposed for
      # testing; it must return the Bearer header for the matching URL.
      assert [{"authorization", "Bearer secret"}] =
               Transport.HTTP.auth_headers_for(t, "https://github.com/user/repo/info/refs")
    end

    test "bound credentials emit NO auth when URL host mismatches" do
      cred = Credentials.host_bound("github.com", {:bearer, "secret"})
      t = Transport.HTTP.new("https://github.com/user/repo", auth: cred)

      # Different host → no header. This is the cross-origin redirect
      # leakage guard; it MUST enforce regardless of where the URL
      # came from.
      assert [] =
               Transport.HTTP.auth_headers_for(t, "https://evil.example.com/steal")
    end

    test "wildcard host_pattern matches subdomain" do
      cred = Credentials.host_bound("*.githubusercontent.com", {:bearer, "tok"})
      t = Transport.HTTP.new("https://raw.githubusercontent.com/x/y", auth: cred)

      assert [{"authorization", _}] =
               Transport.HTTP.auth_headers_for(t, "https://raw.githubusercontent.com/x/y")

      # Different suffix → no auth.
      assert [] =
               Transport.HTTP.auth_headers_for(t, "https://evil.example.com/x")
    end

    test "unbound credentials are usable anywhere (explicit opt-out)" do
      cred = Credentials.unbound({:bearer, "tok"})
      t = Transport.HTTP.new("https://anywhere.example.com/x", auth: cred)

      assert [{"authorization", "Bearer tok"}] =
               Transport.HTTP.auth_headers_for(t, "https://anywhere.example.com/x")
    end

    test "plain auth tuple (no Credentials wrapper) is bound to the URL host by default" do
      # Back-compat: legacy `auth: {:basic, u, p}` callers get automatic
      # host binding to the URL they constructed the transport for. This
      # is the safe default; opt-in cross-host usage requires explicit
      # `Credentials.unbound/1`.
      t = Transport.HTTP.new("https://api.github.com/x", auth: {:basic, "u", "p"})

      assert [{"authorization", "Basic " <> _}] =
               Transport.HTTP.auth_headers_for(t, "https://api.github.com/x")

      assert [] = Transport.HTTP.auth_headers_for(t, "https://evil.example.com/x")
    end
  end

  describe "redirect policy is pinned" do
    test "every request uses redirect: false by default" do
      t = Transport.HTTP.new("https://example.com")
      opts = Transport.HTTP.request_opts(t, :post, "https://example.com/p", [], <<>>)

      assert Keyword.get(opts, :redirect) == false
    end
  end
end
