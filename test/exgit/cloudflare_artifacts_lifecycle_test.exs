defmodule Exgit.CloudflareArtifactsLifecycleTest do
  @moduledoc """
  End-to-end smoketest for the full Cloudflare Artifacts lifecycle
  using a real Cloudflare account.

  Walks the entire control + data plane:

    1. Create a fresh repo (unique name per run).
    2. Mint a write-scoped git token.
    3. Build a commit with exgit and push it via the git wire
       protocol.
    4. Mint a read-scoped git token.
    5. Clone via `Exgit.clone/2` and verify byte-equality of the
       pushed blob.
    6. List tokens, assert both are present and active.
    7. Revoke the write token; assert listing reflects the new state.
    8. Get the repo to confirm metadata.
    9. Delete the repo. Cleanup is also wrapped in `on_exit` so a
       failure mid-test still releases the repo.

  Requires `CF_ACCOUNT_ID` and `CF_API_TOKEN`. Optionally
  `CF_ARTIFACT_NAMESPACE` (defaults to `"default"`).

  Tagged `:cloudflare_api` (distinct from `:cloudflare`, which gates
  the existing wire-protocol roundtrip test against a long-lived
  repo). Run locally with `mix test --include cloudflare_api`.
  `test_helper.exs` excludes this tag automatically when
  `CF_ACCOUNT_ID` / `CF_API_TOKEN` aren't set.
  """

  use ExUnit.Case, async: false
  @moduletag :cloudflare_api

  alias Exgit.CloudflareArtifacts
  alias Exgit.CloudflareArtifacts.{Repo, Token}
  alias Exgit.Credentials.Artifacts, as: ArtifactsCreds
  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport}
  alias Exgit.Test.CloudflareArtifacts, as: CFEnv

  setup_all do
    client =
      CloudflareArtifacts.new(
        account_id: CFEnv.account_id(),
        namespace: CFEnv.namespace(),
        api_token: CFEnv.api_token()
      )

    {:ok, client: client}
  end

  test "full lifecycle: create → tokens → push → fetch → list → revoke → delete", ctx do
    repo_name = "exgit-lc-#{System.system_time(:millisecond)}-#{rand_hex(4)}"
    branch = "refs/heads/main"
    content = :crypto.strong_rand_bytes(2048)

    # Best-effort cleanup even if the test bails midway.
    on_exit(fn ->
      _ = CloudflareArtifacts.delete_repo(ctx.client, repo_name)
    end)

    # 1. Create the repo.
    assert {:ok, %Repo{name: ^repo_name, remote: remote, default_branch: "main"}} =
             CloudflareArtifacts.create_repo(ctx.client,
               name: repo_name,
               default_branch: "main",
               description: "exgit lifecycle smoketest"
             )

    assert is_binary(remote)
    assert remote =~ "/git/#{CFEnv.namespace()}/#{repo_name}.git"

    # 2. Mint a write token. Use a small TTL — well within the
    #    [60, 31_536_000] window from the API constraints memory.
    assert {:ok, %Token{plaintext: write_token, scope: :write, id: write_token_id}} =
             CloudflareArtifacts.create_token(ctx.client,
               repo: repo_name,
               scope: "write",
               ttl: 600
             )

    assert is_binary(write_token)

    # 3. Build a commit and push it to the new repo.
    {repo, commit_sha} = build_single_file_commit(branch, "fixture.bin", content)
    write_transport = Transport.HTTP.new(remote, auth: ArtifactsCreds.auth(write_token))

    assert {:ok, %{ref_results: ref_results}} =
             Exgit.push(repo, write_transport, refspecs: [branch])

    assert Enum.any?(ref_results, &match?({^branch, :ok}, &1))

    # 4. Mint a read token, then clone with it.
    assert {:ok, %Token{plaintext: read_token, scope: :read, id: read_token_id}} =
             CloudflareArtifacts.create_token(ctx.client,
               repo: repo_name,
               scope: :read,
               ttl: 600
             )

    read_transport = Transport.HTTP.new(remote, auth: ArtifactsCreds.auth(read_token))

    # 5. Clone via Exgit and verify the blob round-tripped.
    {:ok, clone} = Exgit.clone(read_transport, lazy: true)
    assert {:ok, ^commit_sha} = RefStore.resolve(clone.ref_store, branch)

    assert {:ok, {_mode, fetched_blob}, _clone} =
             Exgit.FS.read_path(clone, branch, "fixture.bin")

    assert fetched_blob.data == content

    # 6. List tokens — both should appear active. Use the atom-input
    #    form for `state:` to exercise the scope/state coercion path.
    assert {:ok, listed, _info} =
             CloudflareArtifacts.list_tokens(ctx.client, repo_name, state: :all)

    by_id = Map.new(listed, &{&1.id, &1})
    assert %Token{state: :active, scope: :write} = by_id[write_token_id]
    assert %Token{state: :active, scope: :read} = by_id[read_token_id]

    # 7. Revoke the write token.
    assert {:ok, %Token{id: ^write_token_id}} =
             CloudflareArtifacts.delete_token(ctx.client, write_token_id)

    assert {:ok, after_revoke, _info} =
             CloudflareArtifacts.list_tokens(ctx.client, repo_name, state: "all")

    revoked = Enum.find(after_revoke, &(&1.id == write_token_id))
    assert revoked, "revoked token should still appear in state=all listing"
    refute revoked.state == :active

    # 8. Get the repo to confirm metadata is queryable.
    assert {:ok, %Repo{name: ^repo_name, default_branch: "main"}} =
             CloudflareArtifacts.get_repo(ctx.client, repo_name)

    # 9. Delete the repo. The `on_exit` callback will also try to
    #    delete; the second DELETE will 404, which it ignores.
    assert {:ok, %Repo{}} = CloudflareArtifacts.delete_repo(ctx.client, repo_name)
  end

  defp build_single_file_commit(branch, filename, content) do
    store = ObjectStore.Memory.new()
    {:ok, blob_sha, store} = ObjectStore.put(store, Blob.new(content))
    {:ok, tree_sha, store} = ObjectStore.put(store, Tree.new([{"100644", filename, blob_sha}]))

    commit =
      Commit.new(
        tree: tree_sha,
        parents: [],
        author: "Exgit Smoketest <test@exgit> 1700000000 +0000",
        committer: "Exgit Smoketest <test@exgit> 1700000000 +0000",
        message: "exgit lifecycle smoketest\n"
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

  defp rand_hex(n), do: n |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
