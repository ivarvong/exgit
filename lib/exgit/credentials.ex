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

  ## Host matching

  `for_host/2` normalizes the URL's host before comparing it against
  the pattern:

    * case-folded via `String.downcase/1` (ASCII only — we refuse to
      recognize tokens for a Unicode TLD; IDN hosts must be supplied
      in punycode)
    * trailing `.` (DNS fully-qualified form) stripped
    * Unicode/IDN hosts are NOT normalized — callers who need IDN
      matching must provide the punycode host explicitly

  Patterns:

    * Exact hostname: `"github.com"` matches only `github.com`
      (case-insensitive).
    * Wildcard: `"*.githubusercontent.com"` matches
      `githubusercontent.com` AND any `x.githubusercontent.com`. A
      single-component wildcard label is required — the pattern must
      start with `*.`.

  No regex, no substring matching, no glob.
  """

  @type auth :: Exgit.Transport.HTTP.auth_value()

  @type host_cred :: %__MODULE__{host_pattern: String.t() | :any, auth: auth()}

  # The canonical public type. `host_cred` remains as a historical
  # alias and is kept as a synonym.
  @type t :: host_cred()

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
    %__MODULE__{host_pattern: normalize_pattern(pattern), auth: auth}
  end

  @doc """
  Rewrap an existing host-bound credential to bind to `pattern`. Useful
  in a pipeline:

      Credentials.bearer(token) |> Credentials.bind_to("github.com")

  If the input is a bare auth tuple, `bind_to/2` wraps it in a fresh
  `%Credentials{}`. If it's already a `%Credentials{}` struct, the
  existing `auth` is reused with the new pattern.
  """
  @spec bind_to(auth() | host_cred(), String.t()) :: host_cred()
  def bind_to(%__MODULE__{auth: auth}, pattern), do: host_bound(pattern, auth)
  def bind_to(auth, pattern) when is_binary(pattern), do: host_bound(pattern, auth)

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
      %URI{host: host} when is_binary(host) and host != "" ->
        normalized = normalize_host(host)
        if host_matches?(pattern, normalized), do: {:ok, auth}, else: :none

      _ ->
        :none
    end
  end

  # --- Host/pattern normalization ---

  # Patterns are stored normalized: lowercase, no trailing dot. Anything
  # containing non-ASCII is left verbatim (and will never match a
  # normalized host, making it effectively inert). Callers who want IDN
  # matching supply the punycode form.
  defp normalize_pattern(pattern) do
    pattern
    |> String.trim_trailing(".")
    |> ascii_downcase()
  end

  defp normalize_host(host) do
    host
    |> String.trim_trailing(".")
    |> ascii_downcase()
  end

  # ASCII-only lowercase. Unicode case-folding intentionally not used:
  # host comparison must be deterministic and match public suffix
  # conventions, which are ASCII.
  defp ascii_downcase(s) do
    for <<c <- s>>, into: "" do
      if c in ?A..?Z, do: <<c + 32>>, else: <<c>>
    end
  end

  # `"*.foo.com"` matches `foo.com` OR `x.foo.com` OR `a.b.foo.com`.
  # Single leading wildcard label only — no `"a.*.com"` nonsense.
  defp host_matches?("*." <> suffix, host) do
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  defp host_matches?(pattern, host), do: pattern == host
end

defimpl Inspect, for: Exgit.Credentials do
  # Default Inspect impl would dump the raw auth tuple into crash logs,
  # SASL reports, IEx sessions, and telemetry payloads that
  # inadvertently inspect the struct. Always redact.
  def inspect(%Exgit.Credentials{host_pattern: host, auth: auth}, _opts) do
    "#Exgit.Credentials<host: #{inspect(host)}, auth: #{redact(auth)}>"
  end

  defp redact(nil), do: "nil"
  defp redact({:basic, user, _pass}), do: "{:basic, #{inspect(user)}, \"***\"}"
  defp redact({:bearer, _}), do: "{:bearer, \"***\"}"
  defp redact({:header, name, _}), do: "{:header, #{inspect(name)}, \"***\"}"
  defp redact({:callback, _}), do: "{:callback, #Function<...>}"
  defp redact(_), do: ":redacted"
end
