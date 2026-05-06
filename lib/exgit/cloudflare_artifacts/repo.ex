defmodule Exgit.CloudflareArtifacts.Repo do
  @moduledoc """
  Cloudflare Artifacts repository.

  Field names mirror the upstream `RepoInfo` / `RepoWithRemote` /
  `CreateRepoResult` shapes verbatim — `default_branch`, `created_at`,
  `last_push_at`, `read_only`, etc. are kept as-is rather than
  Elixirified, so the struct can be cross-referenced against the
  Cloudflare REST docs directly.

  Not every field is populated by every endpoint:

    * `POST /repos`, `POST /repos/:name/fork`, `POST /repos/:name/import`
      return a `CreateRepoResult` — fills `id`, `name`, `description`,
      `default_branch`, `remote`, `token`. The list/get-only fields
      (`created_at`, `updated_at`, etc.) stay `nil`.
    * `GET /repos`, `GET /repos/:name` return `RepoWithRemote` — fills
      `id`, `name`, `description`, `default_branch`, `created_at`,
      `updated_at`, `last_push_at`, `source`, `read_only`, `remote`.
      `token` is `nil` (those routes don't mint one).
    * Fork additionally returns `objects` (object count copied).
  """

  alias Exgit.CloudflareArtifacts.Repo

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          default_branch: String.t() | nil,
          remote: String.t() | nil,
          token: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          last_push_at: String.t() | nil,
          source: String.t() | nil,
          read_only: boolean() | nil,
          objects: integer() | nil
        }

  defstruct id: nil,
            name: nil,
            description: nil,
            default_branch: nil,
            remote: nil,
            token: nil,
            created_at: nil,
            updated_at: nil,
            last_push_at: nil,
            source: nil,
            read_only: nil,
            objects: nil

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %Repo{
      id: Map.get(map, "id"),
      name: Map.get(map, "name"),
      description: Map.get(map, "description"),
      default_branch: Map.get(map, "default_branch"),
      remote: Map.get(map, "remote"),
      token: Map.get(map, "token"),
      created_at: Map.get(map, "created_at"),
      updated_at: Map.get(map, "updated_at"),
      last_push_at: Map.get(map, "last_push_at"),
      source: Map.get(map, "source"),
      read_only: Map.get(map, "read_only"),
      objects: Map.get(map, "objects")
    }
  end
end

defimpl Inspect, for: Exgit.CloudflareArtifacts.Repo do
  # The `token` field on a Repo is a freshly-minted git auth token
  # — same secrecy class as %Client.api_token. Always redact.
  def inspect(%Exgit.CloudflareArtifacts.Repo{} = r, opts) do
    redacted = if r.token, do: %{r | token: "***"}, else: r
    Inspect.Any.inspect(redacted, opts)
  end
end
