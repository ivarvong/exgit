defmodule Exgit.Test.CloudflareArtifacts do
  @moduledoc """
  Minimal client for the Cloudflare Artifacts REST API, used by the
  roundtrip smoketest to create an ephemeral repo, create repo-scoped
  tokens, and clean up afterwards.

  Two token types are involved:

    * The Cloudflare API token (`CF_API_TOKEN`, prefix `cfat_`) — used
      to authenticate **REST control-plane** calls below.
    * Repo tokens (prefix `art_v1_`) — returned by `create_repo!/2` and
      `create_token!/3`. Used to authenticate **git wire** operations
      against the remote URL.

  Function names mirror the upstream API operations (`Create a repo`,
  `Delete a repo`, `Create a token`, `Revoke a token`).

  Secrets come from environment variables:

    * `CF_API_TOKEN`  — Cloudflare API token with `Artifacts Read` and
      `Artifacts Write` permissions.
    * `CF_ACCOUNT_ID` — the account ID that owns the namespace.

  All functions raise on unexpected non-2xx responses.
  """

  @namespace "default"

  def available? do
    System.get_env("CF_API_TOKEN") not in [nil, ""] and
      System.get_env("CF_ACCOUNT_ID") not in [nil, ""]
  end

  def base_url do
    "https://api.cloudflare.com/client/v4/accounts/#{account_id()}/artifacts/namespaces/#{@namespace}"
  end

  @doc """
  Create a repo (`POST /repos`). Returns
  `{:ok, %{remote: url, token: art_v1_..., ...}}` on success — the
  bootstrap token is repo-scoped (write) and is the only time the API
  returns a token alongside `create`. For additional tokens use
  `create_token!/3`.

  Returns `:already_exists` on 409 (no token returned; caller must
  `create_token!`).
  """
  def create_repo!(name, opts \\ []) do
    body =
      %{name: name}
      |> maybe_put(:description, Keyword.get(opts, :description))
      |> maybe_put(:default_branch, Keyword.get(opts, :default_branch))
      |> maybe_put(:read_only, Keyword.get(opts, :read_only))

    resp =
      Req.request!(
        method: :post,
        url: base_url() <> "/repos",
        headers: api_headers(),
        json: body,
        retry: false
      )

    case resp.status do
      s when s in 200..299 ->
        result = Map.get(resp.body, "result", %{})

        {:ok,
         %{
           id: Map.fetch!(result, "id"),
           name: Map.fetch!(result, "name"),
           default_branch: Map.fetch!(result, "default_branch"),
           remote: Map.fetch!(result, "remote"),
           token: Map.fetch!(result, "token")
         }}

      409 ->
        :already_exists

      _ ->
        raise "create_repo failed: status=#{resp.status} body=#{inspect(resp.body)}"
    end
  end

  @doc """
  Delete a repo (`DELETE /repos/:name`). The API returns `202 Accepted`
  on success. Returns `:ok` on 2xx, `:gone` on 404.
  """
  def delete_repo!(name) do
    resp =
      Req.request!(
        method: :delete,
        url: base_url() <> "/repos/#{name}",
        headers: api_headers(),
        retry: false
      )

    case resp.status do
      s when s in 200..299 -> :ok
      404 -> :gone
      _ -> raise "delete_repo failed: status=#{resp.status} body=#{inspect(resp.body)}"
    end
  end

  @doc """
  Create a repo-scoped git token (`POST /tokens`). Default scope is
  `:write`, default ttl is 3600s.
  """
  def create_token!(repo_name, scope \\ :write, ttl \\ 3600)
      when scope in [:read, :write] and is_integer(ttl) and ttl > 0 do
    resp =
      Req.request!(
        method: :post,
        url: base_url() <> "/tokens",
        headers: api_headers(),
        json: %{repo: repo_name, scope: to_string(scope), ttl: ttl},
        retry: false
      )

    case resp.status do
      s when s in 200..299 ->
        token =
          resp.body
          |> Map.get("result", %{})
          |> Map.get("plaintext")

        if is_binary(token) and token != "",
          do: token,
          else: raise("create_token: missing plaintext in response: #{inspect(resp.body)}")

      _ ->
        raise "create_token failed: status=#{resp.status} body=#{inspect(resp.body)}"
    end
  end

  @doc """
  Revoke a token by id (`DELETE /tokens/:id`). Returns `:ok` on 2xx,
  `:gone` on 404.
  """
  def revoke_token!(token_id) do
    resp =
      Req.request!(
        method: :delete,
        url: base_url() <> "/tokens/#{token_id}",
        headers: api_headers(),
        retry: false
      )

    case resp.status do
      s when s in 200..299 -> :ok
      404 -> :gone
      _ -> raise "revoke_token failed: status=#{resp.status} body=#{inspect(resp.body)}"
    end
  end

  @doc """
  Generate a unique repo name for a test run. Combines a prefix with
  the millisecond timestamp and a short random suffix.
  """
  def unique_name(prefix \\ "exgit-test") do
    suffix =
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)

    "#{prefix}-#{System.system_time(:millisecond)}-#{suffix}"
  end

  # --- Internal ---

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp account_id do
    System.get_env("CF_ACCOUNT_ID") || raise "CF_ACCOUNT_ID not set"
  end

  defp api_token do
    System.get_env("CF_API_TOKEN") || raise "CF_API_TOKEN not set"
  end

  defp api_headers do
    [
      {"authorization", "Bearer " <> api_token()},
      {"content-type", "application/json"}
    ]
  end
end
