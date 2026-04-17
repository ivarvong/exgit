defmodule Exgit.CredentialsHostTest do
  use ExUnit.Case, async: true

  alias Exgit.Credentials

  describe "host-bound credentials (P1.5)" do
    test "Credentials.for_host/2 refuses to provide auth for a non-matching host" do
      cred = Credentials.host_bound("github.com", {:bearer, "ghp_secret"})

      # Matching host yields the auth.
      assert {:ok, {:bearer, "ghp_secret"}} =
               Credentials.for_host(cred, "https://github.com/some/repo")

      # Different host refuses.
      assert :none = Credentials.for_host(cred, "https://evil.example.com/steal")
    end

    test "host matching also covers subdomains under a wildcard" do
      cred = Credentials.host_bound("*.githubusercontent.com", {:bearer, "tok"})

      assert {:ok, _} = Credentials.for_host(cred, "https://raw.githubusercontent.com/x/y")
      assert :none = Credentials.for_host(cred, "https://evil.example.com/x")
    end

    test "unbound credential (no host) is usable anywhere (explicit opt-out of binding)" do
      cred = Credentials.unbound({:bearer, "tok"})

      assert {:ok, {:bearer, "tok"}} =
               Credentials.for_host(cred, "https://anywhere.example.com/x")
    end
  end
end
