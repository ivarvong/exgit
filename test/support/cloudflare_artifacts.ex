defmodule Exgit.Test.CloudflareArtifacts do
  @moduledoc """
  Test-support shim for the Cloudflare Artifacts smoketest.

  The smoketest targets a long-lived persistent repo and authenticates
  git wire operations with a repo-scoped token (prefix `art_v1_`).
  Both the remote URL and token are injected via env vars — locally
  from `.env`, in CI from secrets:

    * `CF_ARTIFACT_REMOTE` — full git wire URL for the test repo
      (`https://<account>.artifacts.cloudflare.net/git/<namespace>/<repo>.git`).
    * `CF_ARTIFACT_TOKEN`  — long-lived repo-scoped token for that repo.

  Because the repo is persistent across runs, tests must use unique
  branch names to avoid stomping each other.
  """

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
end
