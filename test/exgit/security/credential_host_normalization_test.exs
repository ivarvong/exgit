defmodule Exgit.Security.CredentialHostNormalizationTest do
  @moduledoc """
  Regression for review finding #5.

  `Credentials.host_matches?/2` must normalize the URL host before
  comparing to the pattern:

    * case-insensitive (`GITHUB.COM` → `github.com`)
    * trailing-dot stripped (`github.com.` → `github.com`)
    * wildcard `*.foo.com` matches `foo.com` and any subdomain

  Without this, a user-pasted `GITHUB.COM` or `github.com.` URL
  would bypass a `"github.com"`-bound credential and either leak
  the token (if paired with permissive HTTP follow-redirects) or
  simply fail auth silently.
  """

  use ExUnit.Case, async: true

  alias Exgit.Credentials

  describe "for_host/2 matches case-insensitively" do
    test "uppercase host matches lowercase pattern" do
      cred = Credentials.host_bound("github.com", Credentials.bearer("ghp_x"))

      assert {:ok, _} = Credentials.for_host(cred, "https://GITHUB.COM/owner/repo")
      assert {:ok, _} = Credentials.for_host(cred, "https://GitHub.com/owner/repo")
    end

    test "mixed-case pattern normalizes" do
      cred = Credentials.host_bound("GitHub.COM", Credentials.bearer("ghp_x"))

      assert {:ok, _} = Credentials.for_host(cred, "https://github.com/owner/repo")
    end
  end

  describe "for_host/2 strips trailing `.`" do
    test "FQDN host form matches" do
      cred = Credentials.host_bound("github.com", Credentials.bearer("ghp_x"))

      assert {:ok, _} = Credentials.for_host(cred, "https://github.com./owner/repo")
    end

    test "FQDN pattern form also works" do
      cred = Credentials.host_bound("github.com.", Credentials.bearer("ghp_x"))

      assert {:ok, _} = Credentials.for_host(cred, "https://github.com/owner/repo")
    end
  end

  describe "for_host/2 rejects host confusion" do
    test "`evil.comgithub.com` does NOT match `github.com`" do
      cred = Credentials.host_bound("github.com", Credentials.bearer("ghp_x"))

      assert :none = Credentials.for_host(cred, "https://evil.comgithub.com/x")
    end

    test "wildcard matches base domain and subdomains only" do
      cred = Credentials.host_bound("*.github.com", Credentials.bearer("ghp_x"))

      assert {:ok, _} = Credentials.for_host(cred, "https://github.com/x")
      assert {:ok, _} = Credentials.for_host(cred, "https://api.github.com/x")
      assert {:ok, _} = Credentials.for_host(cred, "https://a.b.github.com/x")
      assert :none = Credentials.for_host(cred, "https://evil.github.com.attacker.example/x")
    end
  end

  describe "bind_to/2" do
    test "rewraps a bare auth tuple" do
      cred = Credentials.bearer("ghp_x") |> Credentials.bind_to("github.com")
      assert %Credentials{host_pattern: "github.com"} = cred
    end

    test "rebinds an existing struct to a new pattern" do
      orig = Credentials.host_bound("github.com", Credentials.bearer("ghp_x"))
      new = Credentials.bind_to(orig, "gitlab.com")
      assert new.host_pattern == "gitlab.com"
      assert new.auth == orig.auth
    end
  end

  describe "Inspect redaction" do
    test "struct's default inspect hides the bearer token" do
      cred = Credentials.host_bound("github.com", Credentials.bearer("ghp_secret_token"))
      dumped = inspect(cred)

      refute dumped =~ "ghp_secret_token"
      assert dumped =~ "***"
    end

    test "basic auth password is redacted but username remains" do
      cred = Credentials.host_bound("github.com", Credentials.basic("alice", "secret"))
      dumped = inspect(cred)

      refute dumped =~ "secret"
      assert dumped =~ "alice"
      assert dumped =~ "***"
    end
  end
end
