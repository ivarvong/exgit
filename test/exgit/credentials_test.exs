defmodule Exgit.CredentialsTest do
  use ExUnit.Case, async: true

  alias Exgit.Credentials

  test "basic/2 returns a basic auth tuple" do
    assert {:basic, "user", "pass"} = Credentials.basic("user", "pass")
  end

  test "bearer/1 returns a bearer auth tuple" do
    assert {:bearer, "tok123"} = Credentials.bearer("tok123")
  end

  test "GitHub uses x-access-token as username" do
    assert {:basic, "x-access-token", "ghp_abc"} = Credentials.GitHub.auth("ghp_abc")
  end

  test "GitLab uses oauth2 as username" do
    assert {:basic, "oauth2", "glpat-xyz"} = Credentials.GitLab.auth("glpat-xyz")
  end

  test "Gitea uses bearer token" do
    assert {:bearer, "tok"} = Credentials.Gitea.auth("tok")
  end

  test "BitbucketCloud uses basic auth with username + app password" do
    assert {:basic, "user", "app-pass"} = Credentials.BitbucketCloud.auth("user", "app-pass")
  end

  test "Artifacts uses bearer token" do
    assert {:bearer, "art-tok"} = Credentials.Artifacts.auth("art-tok")
  end

  test "credential values are accepted by Transport.HTTP and auto host-bound" do
    # Legacy API: callers pass a raw auth tuple; Transport.HTTP wraps it
    # in a host-bound %Credentials{} so the token never leaks to a
    # different host if the URL is later mutated or a redirect is
    # attempted cross-origin.
    auth = Credentials.GitHub.auth("ghp_test")
    transport = Exgit.Transport.HTTP.new("https://github.com/foo/bar.git", auth: auth)

    assert %Exgit.Credentials{
             host_pattern: "github.com",
             auth: {:basic, "x-access-token", "ghp_test"}
           } = transport.auth
  end

  test "explicit %Credentials{} is honored without re-wrapping" do
    cred = Credentials.host_bound("custom.example.com", {:bearer, "t"})
    transport = Exgit.Transport.HTTP.new("https://something-else.example.com/r", auth: cred)
    # Passed through unchanged — the caller's binding wins, not the URL's host.
    assert transport.auth == cred
  end

  test "unbound credentials opt out of automatic host binding" do
    cred = Credentials.unbound({:bearer, "t"})
    transport = Exgit.Transport.HTTP.new("https://example.com/r", auth: cred)
    assert transport.auth == cred
  end
end
