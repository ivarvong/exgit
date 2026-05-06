defmodule Exgit.CloudflareArtifacts do
  @moduledoc """
  Cloudflare Artifacts REST API client.

  Wraps the control-plane endpoints documented at
  <https://developers.cloudflare.com/artifacts/api/rest-api/> —
  repos (create / list / get / delete / fork / import) and repo
  tokens (create / list / delete).

  Function and field names mirror upstream verbatim: `create_repo`
  not `mint_repo`, `default_branch` not `branch`, `plaintext` not
  `secret`. The struct shapes (`Repo`, `Token`) match the TypeScript
  interfaces in the upstream docs so the two can be cross-referenced
  directly.

  ## Setup

  `new/1` returns a `%Req.Request{}` with `base_url`, bearer auth,
  and a default user-agent already set:

      client = Exgit.CloudflareArtifacts.new(
        account_id: "abc123",
        namespace: "default",
        api_token: System.fetch_env!("CF_ARTIFACT_API_TOKEN")
      )

  Any extra options (e.g. `:plug` for testing, `:retry`, `:receive_timeout`)
  are forwarded to `Req.new/1`.

  ## Full lifecycle

      {:ok, %Repo{remote: remote}} =
        Exgit.CloudflareArtifacts.create_repo(client,
          name: "starter-repo",
          default_branch: "main"
        )

      {:ok, %Token{plaintext: token}} =
        Exgit.CloudflareArtifacts.create_token(client,
          repo: "starter-repo",
          scope: "write",
          ttl: 86_400
        )

      transport = Exgit.Transport.HTTP.new(remote,
        auth: Exgit.Credentials.Artifacts.auth(token)
      )

      # ... push, fetch, clone via the existing transport ...

      {:ok, _} = Exgit.CloudflareArtifacts.delete_repo(client, "starter-repo")

  ## Return shapes

  Single-resource endpoints return `{:ok, struct}`. List endpoints
  return `{:ok, items, result_info}` — `result_info` is the upstream
  pagination map verbatim (cursor for repos, offset for tokens).

  Errors:

    * `{:error, %Req.Response{}}` — non-2xx, or 2xx with `success:
      false`. The parsed v4 envelope is in `body`; the upstream error
      list lives at `body["errors"]` (each entry has `code`,
      `message`, optional `documentation_url`).
    * `{:error, exception}` — Req-level transport failure (DNS, TLS,
      connection refused, etc.).

  Pattern-match on specific upstream codes directly:

      case Exgit.CloudflareArtifacts.create_token(client, repo: r, ttl: 99_999_999) do
        {:error, %Req.Response{body: %{"errors" => [%{"code" => 10103} | _]}}} ->
          :ttl_out_of_range
        ...
      end
  """

  alias Exgit.CloudflareArtifacts.{Repo, Token}

  @default_base_url "https://api.cloudflare.com/client/v4"

  @doc """
  Build a configured `%Req.Request{}` for the Cloudflare Artifacts API.

  Required: `:account_id`, `:api_token`. Optional: `:namespace`
  (defaults to `"default"`), `:base_url`. Any other keys (`:plug`,
  `:retry`, `:receive_timeout`, …) are forwarded to `Req.new/1`.
  """
  @spec new(keyword()) :: Req.Request.t()
  def new(opts) do
    {own, rest} = Keyword.split(opts, [:account_id, :namespace, :api_token, :base_url])
    account_id = Keyword.fetch!(own, :account_id)
    api_token = Keyword.fetch!(own, :api_token)
    namespace = Keyword.get(own, :namespace, "default")
    base = own |> Keyword.get(:base_url, @default_base_url) |> String.trim_trailing("/")

    Req.new(
      [
        base_url: "#{base}/accounts/#{account_id}/artifacts/namespaces/#{namespace}",
        auth: {:bearer, api_token},
        headers: [{"user-agent", "exgit/0.1.0"}]
      ] ++ rest
    )
  end

  # --- Repos ---

  @doc """
  Create a repo. `POST /repos`.

  Required option: `:name`. Optional: `:description`,
  `:default_branch`, `:read_only`. The returned `Repo` includes a
  short-lived inline `:token` — use `create_token/2` for longer TTLs.
  """
  @spec create_repo(Req.Request.t(), keyword()) :: {:ok, Repo.t()} | {:error, term()}
  def create_repo(req, opts) do
    body = json_body(opts, [:name, :description, :default_branch, :read_only])

    req
    |> Req.post(url: "/repos", json: body)
    |> handle(&Repo.from_map/1)
  end

  @doc """
  List repos. `GET /repos`.

  Optional: `:limit` (default 50, max 200), `:cursor`, `:search`,
  `:sort` (`"created_at" | "updated_at" | "last_push_at" | "name"`),
  `:direction` (`"asc" | "desc"`).
  """
  @spec list_repos(Req.Request.t(), keyword()) ::
          {:ok, [Repo.t()], map()} | {:error, term()}
  def list_repos(req, opts \\ []) do
    params = Keyword.take(opts, [:limit, :cursor, :search, :sort, :direction])

    req
    |> Req.get(url: "/repos", params: params)
    |> handle_list(&Repo.from_map/1)
  end

  @doc """
  Get a repo by name. `GET /repos/:name`.
  """
  @spec get_repo(Req.Request.t(), String.t()) :: {:ok, Repo.t()} | {:error, term()}
  def get_repo(req, name) when is_binary(name) do
    req
    |> Req.get(url: "/repos/:name", path_params: [name: name])
    |> handle(&Repo.from_map/1)
  end

  @doc """
  Delete a repo. `DELETE /repos/:name`. Returns 202 upstream; the
  resulting `Repo` carries only `:id`.
  """
  @spec delete_repo(Req.Request.t(), String.t()) :: {:ok, Repo.t()} | {:error, term()}
  def delete_repo(req, name) when is_binary(name) do
    req
    |> Req.delete(url: "/repos/:name", path_params: [name: name])
    |> handle(&Repo.from_map/1)
  end

  @doc """
  Fork a repo. `POST /repos/:name/fork`.

  Required option: `:name` (the new repo). Optional: `:description`,
  `:read_only`, `:default_branch_only`. The returned `Repo` adds an
  `:objects` count.
  """
  @spec fork_repo(Req.Request.t(), String.t(), keyword()) ::
          {:ok, Repo.t()} | {:error, term()}
  def fork_repo(req, source_name, opts) when is_binary(source_name) do
    body = json_body(opts, [:name, :description, :read_only, :default_branch_only])

    req
    |> Req.post(url: "/repos/:name/fork", path_params: [name: source_name], json: body)
    |> handle(&Repo.from_map/1)
  end

  @doc """
  Import a public HTTPS git remote. `POST /repos/:name/import`.

  `name` is the destination repo name; `:url` in the body is the
  HTTPS source remote. Optional body fields: `:branch`, `:depth`,
  `:read_only`. May 409 while a previous import/fork is still in
  progress.
  """
  @spec import_repo(Req.Request.t(), String.t(), keyword()) ::
          {:ok, Repo.t()} | {:error, term()}
  def import_repo(req, name, opts) when is_binary(name) do
    body = json_body(opts, [:url, :branch, :depth, :read_only])

    req
    |> Req.post(url: "/repos/:name/import", path_params: [name: name], json: body)
    |> handle(&Repo.from_map/1)
  end

  # --- Tokens ---

  @doc """
  Mint a repo-scoped token. `POST /tokens`.

  Required option: `:repo`. Optional: `:scope` (`"read" | "write"` or
  the matching atoms `:read | :write`; default `"write"`), `:ttl`
  (seconds, default 86_400; capped at 31_536_000 — `code: 10103` if
  exceeded). Returns a `Token` with `:plaintext` set.
  """
  @spec create_token(Req.Request.t(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def create_token(req, opts) do
    body = json_body(opts, [:repo, :scope, :ttl])

    req
    |> Req.post(url: "/tokens", json: body)
    |> handle(&Token.from_map/1)
  end

  @doc """
  List tokens for a repo. `GET /repos/:name/tokens`.

  Optional: `:state` (`"active" | "expired" | "revoked" | "all"` or
  the matching atoms `:active | :expired | :revoked | :all`; default
  `"active"`), `:per_page` (default 30, max 100), `:page` (default
  1). Listed tokens have `:plaintext` set to `nil` — the API never
  re-emits the secret.
  """
  @spec list_tokens(Req.Request.t(), String.t(), keyword()) ::
          {:ok, [Token.t()], map()} | {:error, term()}
  def list_tokens(req, repo_name, opts \\ []) when is_binary(repo_name) do
    params =
      opts
      |> Keyword.take([:state, :per_page, :page])
      |> Enum.map(fn {k, v} -> {k, stringify_atom(v)} end)

    req
    |> Req.get(url: "/repos/:name/tokens", path_params: [name: repo_name], params: params)
    |> handle_list(&Token.from_map/1)
  end

  @doc """
  Revoke a token. `DELETE /tokens/:id`. The returned `Token` carries
  only `:id`.
  """
  @spec delete_token(Req.Request.t(), String.t()) :: {:ok, Token.t()} | {:error, term()}
  def delete_token(req, token_id) when is_binary(token_id) do
    req
    |> Req.delete(url: "/tokens/:id", path_params: [id: token_id])
    |> handle(&Token.from_map/1)
  end

  # --- Helpers ---

  defp json_body(opts, keys) do
    for k <- keys, {:ok, v} <- [Keyword.fetch(opts, k)], not is_nil(v), into: %{} do
      {Atom.to_string(k), stringify_atom(v)}
    end
  end

  # Coerce atom enum values (`:read`, `:active`, …) to their string
  # form so callers can pass either. Booleans and non-atoms pass
  # through unchanged so JSON booleans/numbers still encode correctly.
  defp stringify_atom(v) when is_boolean(v), do: v
  defp stringify_atom(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_atom(v), do: v

  defp handle({:ok, %Req.Response{status: s, body: %{"success" => true, "result" => r}}}, parser)
       when s in 200..299 and is_map(r) do
    {:ok, parser.(r)}
  end

  defp handle({:ok, %Req.Response{} = resp}, _parser), do: {:error, resp}
  defp handle({:error, exception}, _parser), do: {:error, exception}

  defp handle_list(
         {:ok, %Req.Response{status: s, body: %{"success" => true, "result" => r} = env}},
         parser
       )
       when s in 200..299 and is_list(r) do
    {:ok, Enum.map(r, parser), Map.get(env, "result_info", %{})}
  end

  defp handle_list({:ok, %Req.Response{} = resp}, _parser), do: {:error, resp}
  defp handle_list({:error, exception}, _parser), do: {:error, exception}
end
