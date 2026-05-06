defmodule Exgit.CloudflareArtifacts.Token do
  @moduledoc """
  Cloudflare Artifacts repo-scoped token.

  This struct represents both shapes the API can return:

    * `POST /tokens` (`CreateTokenResult`) — populates `id`, `plaintext`,
      `scope`, `expires_at`. Listing fields (`state`, `created_at`)
      stay `nil`.
    * `GET /repos/:name/tokens` (`TokenInfo`) — populates `id`, `scope`,
      `state`, `created_at`, `expires_at`. The actual token bytes are
      not returned — `plaintext` stays `nil`.

  Field names match upstream verbatim (`plaintext`, not `secret` or
  `value`).

  The `plaintext` value is opaque — pass it through to git wire auth
  via `Exgit.Credentials.Artifacts.auth/1` (bearer header) without
  modification. The expiration is already exposed as the `expires_at`
  ISO timestamp on the struct, so callers don't need to parse the
  embedded `?expires=<unix>` suffix.
  """

  alias Exgit.CloudflareArtifacts.Token

  @type scope :: :read | :write
  @type state :: :active | :expired | :revoked

  @type t :: %__MODULE__{
          id: String.t() | nil,
          plaintext: String.t() | nil,
          scope: scope() | nil,
          state: state() | nil,
          created_at: String.t() | nil,
          expires_at: String.t() | nil
        }

  defstruct id: nil,
            plaintext: nil,
            scope: nil,
            state: nil,
            created_at: nil,
            expires_at: nil

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %Token{
      id: Map.get(map, "id"),
      plaintext: Map.get(map, "plaintext"),
      scope: parse_scope(Map.get(map, "scope")),
      state: parse_state(Map.get(map, "state")),
      created_at: Map.get(map, "created_at"),
      expires_at: Map.get(map, "expires_at")
    }
  end

  defp parse_scope("read"), do: :read
  defp parse_scope("write"), do: :write
  defp parse_scope(_), do: nil

  defp parse_state("active"), do: :active
  defp parse_state("expired"), do: :expired
  defp parse_state("revoked"), do: :revoked
  defp parse_state(_), do: nil
end

defimpl Inspect, for: Exgit.CloudflareArtifacts.Token do
  # `plaintext` is the literal git-auth secret; never echo it.
  def inspect(%Exgit.CloudflareArtifacts.Token{} = t, opts) do
    redacted = if t.plaintext, do: %{t | plaintext: "***"}, else: t
    Inspect.Any.inspect(redacted, opts)
  end
end
