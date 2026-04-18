defmodule Exgit.Security.CallbackAuthTest do
  use ExUnit.Case, async: true

  alias Exgit.{Credentials, Transport}

  describe "{:callback, fun} auth (S4)" do
    test "callback receives the request URL and returns headers" do
      fun = fn url ->
        send(self(), {:called, url})
        [{"x-signed", "fingerprint=" <> String.slice(url, 0, 20)}]
      end

      t =
        Transport.HTTP.new("https://example.com/repo",
          auth: Credentials.unbound({:callback, fun})
        )

      headers = Transport.HTTP.auth_headers_for(t, "https://example.com/repo/info/refs")

      assert [{"x-signed", value}] = headers
      assert String.starts_with?(value, "fingerprint=")
    end

    test "callback is host-bound when wrapped in Credentials.host_bound" do
      fun = fn _url -> [{"authorization", "callback-computed"}] end

      t =
        Transport.HTTP.new("https://example.com/repo",
          auth: Credentials.host_bound("example.com", {:callback, fun})
        )

      assert [{"authorization", _}] =
               Transport.HTTP.auth_headers_for(t, "https://example.com/repo")

      # Different host → no headers even though the callback would
      # happily return them.
      assert [] = Transport.HTTP.auth_headers_for(t, "https://other.example.com/x")
    end
  end
end
