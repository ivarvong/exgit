defmodule Exgit.Credentials do
  @moduledoc """
  Helpers for constructing transport auth values, plus a small
  host-scoped credential mechanism.

  The flat constructors (`basic/2`, `bearer/1`) return raw auth tuples
  suitable for `Exgit.Transport.HTTP.new/2` — callers who know exactly
  which URL they're talking to typically use these directly.

  `host_bound/2` and `for_host/2` add a safety rail: a credential is
  only surrendered when the target URL's host matches the bound
  pattern. This guards against accidentally leaking a GitHub token to
  an attacker-controlled redirect, a CI misconfiguration, or a user-
  supplied URL that points somewhere unexpected.
  """

  @type auth :: Exgit.Transport.HTTP.auth()

  @type host_cred :: %__MODULE__{host_pattern: String.t() | :any, auth: auth()}

  defstruct [:host_pattern, :auth]

  # --- Raw constructors ---

  @spec basic(String.t(), String.t()) :: auth()
  def basic(user, password), do: {:basic, user, password}

  @spec bearer(String.t()) :: auth()
  def bearer(token), do: {:bearer, token}

  # --- Host-bound credentials ---

  @doc """
  Wrap an auth value with a host pattern. The pattern is either a bare
  hostname (`"github.com"`) or a wildcard (`"*.githubusercontent.com"`).
  Use `for_host/2` to extract the auth when (and only when) the URL
  matches.
  """
  @spec host_bound(String.t(), auth()) :: host_cred()
  def host_bound(pattern, auth) when is_binary(pattern) do
    %__MODULE__{host_pattern: pattern, auth: auth}
  end

  @doc """
  Wrap an auth value without a host binding. Emits the auth for any
  URL — caller has explicitly opted out of scoping.
  """
  @spec unbound(auth()) :: host_cred()
  def unbound(auth), do: %__MODULE__{host_pattern: :any, auth: auth}

  @doc """
  Return the auth value iff the credential's host binding matches the
  given URL. Returns `:none` otherwise.
  """
  @spec for_host(host_cred(), String.t()) :: {:ok, auth()} | :none
  def for_host(%__MODULE__{host_pattern: :any, auth: auth}, _url), do: {:ok, auth}

  def for_host(%__MODULE__{host_pattern: pattern, auth: auth}, url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if host_matches?(pattern, host), do: {:ok, auth}, else: :none

      _ ->
        :none
    end
  end

  defp host_matches?("*." <> suffix, host) do
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  defp host_matches?(pattern, host), do: pattern == host
end
