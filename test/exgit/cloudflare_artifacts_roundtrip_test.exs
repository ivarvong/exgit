defmodule Exgit.CloudflareArtifactsRoundtripTest do
  @moduledoc """
  Live smoketest against Cloudflare Artifacts.

  Creates an ephemeral repo via the Artifacts REST API, pushes an
  exgit-built commit over the git smart-HTTP endpoint using the
  repo-scoped token returned by `create_repo`, then verifies the data
  two ways:

    1. **exgit ↔ exgit** — lazy-clone via `Exgit.clone`, read the blob
       back, assert byte-equality with the random content we pushed.
       Catches push/parse/transport bugs in our own code.

    2. **exgit ↔ real git** — `git clone` with the real binary, then
       `git fsck`. Proves the bytes Cloudflare stored are valid git
       (not just exgit-flavoured), and that a third-party client can
       read them.

  Tagged `:cloudflare`. Run with `mix test --include cloudflare`.
  The real-git verification is also tagged `:real_git`.

  Secrets (loaded by `test_helper.exs`):

    * `CF_API_TOKEN`  — Cloudflare API token with `Artifacts Read` and
      `Artifacts Write` permissions.
    * `CF_ACCOUNT_ID` — owning account.
  """

  use ExUnit.Case, async: false
  @moduletag :cloudflare

  alias Exgit.Credentials.Artifacts, as: ArtifactsCreds
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport}
  alias Exgit.Test.{CloudflareArtifacts, RealGit}

  setup_all do
    name = CloudflareArtifacts.unique_name("exgit-rt")
    {:ok, repo_info} = CloudflareArtifacts.create_repo!(name, default_branch: "main")
    on_exit(fn -> _ = CloudflareArtifacts.delete_repo!(name) end)

    %{
      repo_name: name,
      remote: repo_info.remote,
      token: repo_info.token,
      default_branch: repo_info.default_branch
    }
  end

  defp transport(remote, token) do
    Transport.HTTP.new(remote, auth: ArtifactsCreds.auth(token))
  end

  defp unique_branch do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "refs/heads/exgit-rt-#{System.system_time(:millisecond)}-#{suffix}"
  end

  # Build a single-file commit. Returns {repo, commit_sha, content}.
  defp build_commit(branch, filename, content) do
    store = ObjectStore.Memory.new()
    {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new(content))
    {:ok, tree_sha, store} = ObjectStore.put(store, Tree.new([{"100644", filename, blob_sha}]))

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "Exgit Smoketest <test@exgit> 1700000000 +0000",
        committer: "Exgit Smoketest <test@exgit> 1700000000 +0000",
        message: "cloudflare artifacts smoketest\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)
    {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), branch, commit_sha, [])

    repo = %Repository{
      object_store: store,
      ref_store: ref_store,
      config: Exgit.Config.new(),
      path: nil
    }

    {repo, commit_sha}
  end

  defp tmp_dir!(prefix) do
    base = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(base)
    base
  end

  test "exgit push → exgit clone roundtrips a random blob", ctx do
    branch = unique_branch()
    content = :crypto.strong_rand_bytes(4096)
    {repo, commit_sha} = build_commit(branch, "fixture.bin", content)

    t = transport(ctx.remote, ctx.token)

    assert {:ok, _} = Exgit.push(repo, t, refspecs: [branch])

    {:ok, clone} = Exgit.clone(t, lazy: true)
    assert {:ok, ^commit_sha} = RefStore.resolve(clone.ref_store, branch)

    assert {:ok, {_mode, fetched_blob}, _clone} =
             Exgit.FS.read_path(clone, branch, "fixture.bin")

    assert fetched_blob.data == content
  end

  @tag :real_git
  test "exgit-pushed commit is readable by real git clone + fsck", ctx do
    branch = unique_branch()
    branch_name = String.trim_leading(branch, "refs/heads/")
    content = "Pushed by exgit at #{System.system_time(:millisecond)}\n"
    {repo, _commit_sha} = build_commit(branch, "hello.txt", content)

    assert {:ok, _} = Exgit.push(repo, transport(ctx.remote, ctx.token), refspecs: [branch])

    clone_dir = tmp_dir!("exgit_cf_clone")

    try do
      {out, status} =
        System.cmd(
          "git",
          [
            "-c",
            "http.extraheader=Authorization: Bearer #{ctx.token}",
            "clone",
            "--branch",
            branch_name,
            "--depth",
            "1",
            ctx.remote,
            clone_dir
          ],
          stderr_to_stdout: true
        )

      assert status == 0, "git clone failed:\n#{out}"
      assert File.read!(Path.join(clone_dir, "hello.txt")) == content

      {out, status} = RealGit.git!(clone_dir, ["fsck", "--full"], allow_error: true)
      assert status == 0, "git fsck failed:\n#{out}"
    after
      File.rm_rf!(clone_dir)
    end
  end
end
