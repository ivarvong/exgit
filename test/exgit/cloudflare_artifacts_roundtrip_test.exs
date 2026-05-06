defmodule Exgit.CloudflareArtifactsRoundtripTest do
  @moduledoc """
  Live smoketest against Cloudflare Artifacts.

  Pushes an exgit-built commit over the git smart-HTTP endpoint to a
  long-lived persistent repo (URL + token injected via
  `CF_ARTIFACT_REMOTE` and `CF_ARTIFACT_TOKEN`), then verifies the data
  two ways:

    1. **exgit ↔ exgit** — lazy-clone via `Exgit.clone`, read the blob
       back, assert byte-equality with the random content we pushed.
       Catches push/parse/transport bugs in our own code.

    2. **exgit ↔ real git** — `git clone` with the real binary, then
       `git fsck`. Proves the bytes Cloudflare stored are valid git
       (not just exgit-flavoured), and that a third-party client can
       read them.

  Each test uses a unique branch name; the underlying repo is shared
  across runs.

  Tagged `:cloudflare`. Run with `mix test --include cloudflare`.
  Test 2 shells out to the `git` binary; opting into `:cloudflare`
  implies `git` is on PATH.
  """

  use ExUnit.Case, async: false
  @moduletag :cloudflare

  alias Exgit.Credentials.Artifacts, as: ArtifactsCreds
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport}
  alias Exgit.Test.{CloudflareArtifacts, RealGit}

  defp transport do
    Transport.HTTP.new(CloudflareArtifacts.remote(),
      auth: ArtifactsCreds.auth(CloudflareArtifacts.token())
    )
  end

  defp unique_branch do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "refs/heads/exgit-rt-#{System.system_time(:millisecond)}-#{suffix}"
  end

  # Build a single-file commit. Returns {repo, commit_sha}.
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

  test "exgit push → exgit clone roundtrips a random blob" do
    branch = unique_branch()
    content = :crypto.strong_rand_bytes(4096)
    {repo, commit_sha} = build_commit(branch, "fixture.bin", content)

    t = transport()

    assert {:ok, _} = Exgit.push(repo, t, refspecs: [branch])

    {:ok, clone} = Exgit.clone(t, lazy: true)
    assert {:ok, ^commit_sha} = RefStore.resolve(clone.ref_store, branch)

    assert {:ok, {_mode, fetched_blob}, _clone} =
             Exgit.FS.read_path(clone, branch, "fixture.bin")

    assert fetched_blob.data == content
  end

  test "exgit-pushed commit is readable by real git clone + fsck" do
    branch = unique_branch()
    branch_name = String.trim_leading(branch, "refs/heads/")
    content = "Pushed by exgit at #{System.system_time(:millisecond)}\n"
    {repo, _commit_sha} = build_commit(branch, "hello.txt", content)

    assert {:ok, _} = Exgit.push(repo, transport(), refspecs: [branch])

    clone_dir = tmp_dir!("exgit_cf_clone")

    try do
      {out, status} =
        System.cmd(
          "git",
          [
            "-c",
            "http.extraheader=Authorization: Bearer #{CloudflareArtifacts.token()}",
            "clone",
            "--branch",
            branch_name,
            "--depth",
            "1",
            CloudflareArtifacts.remote(),
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
