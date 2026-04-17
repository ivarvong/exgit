defmodule Exgit.Test.CloudflareArtifacts do
  @moduledoc """
  Minimal client for the Cloudflare Artifacts REST API, used by the
  roundtrip smoketest to create an ephemeral repo, mint a write token,
  and clean up afterwards.

  Secrets come from environment variables:

    * `CF_API_TOKEN`  — a Cloudflare API token with Artifacts Edit.
    * `CF_ACCOUNT_ID` — the account ID that owns the namespace.

  All functions raise on non-2xx responses so test failures surface
  immediately.
  """

  @namespace "default"

  def available? do
    System.get_env("CF_API_TOKEN") not in [nil, ""] and
      System.get_env("CF_ACCOUNT_ID") not in [nil, ""]
  end

  def base_url do
    "https://api.cloudflare.com/client/v4/accounts/#{account_id()}/artifacts/namespaces/#{@namespace}"
  end

  def git_url(repo_name) do
    "https://#{account_id()}.artifacts.cloudflare.net/git/#{@namespace}/#{repo_name}.git"
  end

  @doc "Create a repo. Idempotent on 409 (already exists)."
  def create_repo!(name) do
    resp =
      Req.request!(
        method: :post,
        url: base_url() <> "/repos",
        headers: api_headers(),
        json: %{name: name},
        retry: false
      )

    case resp.status do
      s when s in 200..299 -> :ok
      409 -> :already_exists
      _ -> raise "create_repo failed: status=#{resp.status} body=#{inspect(resp.body)}"
    end
  end

  @doc "Delete the repo (irreversible)."
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

  @doc "Mint a repo-scoped token. `scope` is :read or :write."
  def mint_token!(repo_name, scope) when scope in [:read, :write] do
    resp =
      Req.request!(
        method: :post,
        url: base_url() <> "/repos/#{repo_name}/tokens",
        headers: api_headers(),
        json: %{scope: to_string(scope)},
        retry: false
      )

    case resp.status do
      s when s in 200..299 ->
        token =
          resp.body
          |> Map.get("result", %{})
          |> Map.get("token")

        if is_binary(token) and token != "",
          do: token,
          else: raise("mint_token: missing token in response: #{inspect(resp.body)}")

      _ ->
        raise "mint_token failed: status=#{resp.status} body=#{inspect(resp.body)}"
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
