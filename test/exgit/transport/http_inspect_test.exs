defmodule Exgit.Transport.HttpInspectTest do
  use ExUnit.Case, async: true

  alias Exgit.Transport.HTTP

  describe "Inspect does not leak credentials (P0.6)" do
    test "basic auth password never appears in inspect output" do
      secret = "totally_secret_pw_9fj3k"
      t = HTTP.new("https://example.com/repo", auth: {:basic, "user", secret})
      refute inspect(t) =~ secret
    end

    test "bearer token never appears in inspect output" do
      secret = "ghp_abcdefghijklmnop123"
      t = HTTP.new("https://example.com/repo", auth: {:bearer, secret})
      refute inspect(t) =~ secret
    end

    test "header-style auth value never appears" do
      secret = "custom_secret_value_xyz"
      t = HTTP.new("https://example.com/repo", auth: {:header, "x-auth", secret})
      refute inspect(t) =~ secret
    end

    test "the URL is still visible for debugging" do
      t = HTTP.new("https://example.com/repo", auth: {:bearer, "x"})
      assert inspect(t) =~ "example.com/repo"
    end

    test "when there is no auth, inspect reads naturally" do
      t = HTTP.new("https://example.com/repo")
      s = inspect(t)
      refute s =~ "***"
      assert s =~ "example.com/repo"
    end
  end
end
