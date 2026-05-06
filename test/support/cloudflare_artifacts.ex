defmodule Exgit.Test.CloudflareArtifacts do
  @moduledoc """
  Test-support shim for the Cloudflare Artifacts smoketests.

  Two modes are supported via different env vars:

  ## Long-lived repo mode (`cloudflare_artifacts_roundtrip_test.exs`)

  Targets a pre-provisioned repo with an injected token; tests push
  unique branches to it.

    * `CF_ARTIFACT_REMOTE` — full git wire URL for the test repo
      (`https://<account>.artifacts.cloudflare.net/git/<namespace>/<repo>.git`).
    * `CF_ARTIFACT_TOKEN`  — long-lived repo-scoped token for that repo.

  ## Full-lifecycle mode (`cloudflare_artifacts_lifecycle_test.exs`)

  Uses a Cloudflare API token to create a fresh repo, mint git
  tokens, exercise the wire protocol, and tear everything down.

    * `CF_ACCOUNT_ID`         — Cloudflare account ID. Generic
      Cloudflare credential, not artifact-specific.
    * `CF_API_TOKEN`          — Cloudflare API token with
      `Artifacts > Edit` permission. Generic.
    * `CF_ARTIFACT_NAMESPACE` — optional, defaults to `"default"`.
      Artifact-specific.
  """

  # --- Long-lived mode ---

  def available? do
    System.get_env("CF_ARTIFACT_REMOTE") not in [nil, ""] and
      System.get_env("CF_ARTIFACT_TOKEN") not in [nil, ""]
  end

  def remote do
    System.get_env("CF_ARTIFACT_REMOTE") || raise "CF_ARTIFACT_REMOTE not set"
  end

  def token do
    System.get_env("CF_ARTIFACT_TOKEN") || raise "CF_ARTIFACT_TOKEN not set"
  end

  # --- Full-lifecycle mode ---

  def api_available? do
    System.get_env("CF_ACCOUNT_ID") not in [nil, ""] and
      System.get_env("CF_API_TOKEN") not in [nil, ""]
  end

  def account_id do
    System.get_env("CF_ACCOUNT_ID") || raise "CF_ACCOUNT_ID not set"
  end

  def api_token do
    System.get_env("CF_API_TOKEN") || raise "CF_API_TOKEN not set"
  end

  def namespace, do: System.get_env("CF_ARTIFACT_NAMESPACE") || "default"
end
