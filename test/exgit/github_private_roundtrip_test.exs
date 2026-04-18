defmodule Exgit.GithubPrivateRoundtripTest do
  @moduledoc """
  Live smoketest against a private GitHub repo using a Personal Access
  Token over HTTPS.

  Secrets (loaded from `.env` by `test_helper.exs`):

    * `GITHUB_PAT` — a PAT with access to
      `https://github.com/ivarvong/exgit_smoketest`.

  ## Tags

    * `:github_private` — all tests in this module. Run with
      `mix test --include github_private`.
    * `:github_private_write` — only tests that attempt a push.
      Require the PAT to have **Contents: Read and write** permission
      (fine-grained) or `repo` scope (classic).

  ## Auth format

  GitHub's git-over-HTTPS endpoints use Basic auth with a placeholder
  username and the PAT as password — NOT bearer tokens. Bearer tokens
  work for the REST API but are rejected by `/info/refs` and
  `/git-upload-pack`.
  """

  use ExUnit.Case, async: false
  @moduletag :github_private

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport}
  alias Exgit.Test.RealGit

  @repo_url "https://github.com/ivarvong/exgit_smoketest"

  # ---- setup ----

  setup_all do
    case System.get_env("GITHUB_PAT") do
      nil ->
        {:skip, "GITHUB_PAT not set"}

      "" ->
        {:skip, "GITHUB_PAT not set"}

      _pat ->
        # Ensure the repo has a default branch pinned to `main`. Without
        # this, the first test that pushes an `exgit-smoketest-*` branch
        # to an empty repo makes that branch the default, which GitHub
        # then refuses to delete during cleanup.
        ensure_default_branch!()
        :ok
    end
  end

  # REST-based helpers used only in setup. We hit the v3 API to:
  #   1. Check if `main` exists as the default branch.
  #   2. If not, create an initial commit via the Contents API so `main`
  #      exists before any test-specific branches are pushed.
  defp ensure_default_branch! do
    pat = System.get_env("GITHUB_PAT")

    headers = [
      {"authorization", "Bearer " <> pat},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    api = "https://api.github.com/repos/ivarvong/exgit_smoketest"

    case Req.get!(url: api <> "/branches/main", headers: headers, retry: false) do
      %Req.Response{status: 200} ->
        :ok

      %Req.Response{status: 404} ->
        # Create README.md on main via Contents API — this also creates
        # the main branch.
        Req.put!(
          url: api <> "/contents/README.md",
          headers: headers,
          json: %{
            message: "initial commit (exgit smoketest bootstrap)",
            content: Base.encode64("# exgit_smoketest\n"),
            branch: "main"
          },
          retry: false
        )

        :ok

      %Req.Response{status: status, body: body} ->
        raise "ensure_default_branch: unexpected status=#{status} body=#{inspect(body)}"
    end
  end

  defp transport do
    Transport.HTTP.new(@repo_url,
      auth: {:basic, "x-access-token", System.get_env("GITHUB_PAT")}
    )
  end

  defp unique_branch do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "refs/heads/exgit-smoketest-#{System.system_time(:millisecond)}-#{suffix}"
  end

  # Best-effort branch deletion on the remote. Ignores failures so
  # cleanup can't mask the actual test error.
  defp cleanup_branch(ref) do
    try do
      Exgit.push(empty_repo(), transport(), refspecs: [{:delete, ref}])
    rescue
      _ -> :ok
    end
  end

  defp empty_repo do
    %Repository{
      object_store: ObjectStore.Memory.new(),
      ref_store: RefStore.Memory.new(),
      config: Exgit.Config.new(),
      path: nil
    }
  end

  # ---- read-path tests (need only read access) ----

  describe "read path — works with any PAT that can access the repo" do
    test "HTTPS + PAT basic auth lists refs on a private repo" do
      assert {:ok, refs, _meta} = Transport.ls_refs(transport(), prefix: ["refs/heads/"])
      assert is_list(refs)
    end

    test "lazy clone returns a usable repo with populated ref_store" do
      assert {:ok, repo} = Exgit.clone(transport(), lazy: true)

      # Even on an empty repo this returns {:ok, repo} with no refs —
      # and on a populated repo we get real refs back.
      assert %Repository{mode: :lazy} = repo
    end
  end

  # ---- write-path tests (need PAT with Contents: Read and write) ----

  describe "write path — requires a PAT with write access" do
    @describetag :github_private_write

    test "random file roundtrips byte-for-byte via exgit push + exgit clone" do
      branch = unique_branch()

      content = :crypto.strong_rand_bytes(4096)
      blob = Blob.new(content)

      store = ObjectStore.Memory.new()
      {:ok, blob_sha, store} = ObjectStore.put(store, blob)

      tree = Tree.new([{"100644", "fixture.bin", blob_sha}])
      {:ok, tree_sha, store} = ObjectStore.put(store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "Exgit Test <test@exgit> 1700000000 +0000",
          committer: "Exgit Test <test@exgit> 1700000000 +0000",
          message: "exgit smoketest\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), branch, commit_sha, [])

      repo = %Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      try do
        assert {:ok, _} = Exgit.push(repo, transport(), refspecs: [branch])

        {:ok, clone} = Exgit.clone(transport(), lazy: true)
        assert {:ok, ^commit_sha} = RefStore.resolve(clone.ref_store, branch)

        assert {:ok, {_mode, fetched_blob}, _clone} =
                 Exgit.FS.read_path(clone, branch, "fixture.bin")

        assert fetched_blob.data == content
      after
        cleanup_branch(branch)
      end
    end

    test "exgit-pushed commit is visible to real git clone" do
      branch = unique_branch()
      branch_name = String.trim_leading(branch, "refs/heads/")

      content = "Pushed by exgit at #{System.system_time(:millisecond)}\n"
      blob = Blob.new(content)

      store = ObjectStore.Memory.new()
      {:ok, blob_sha, store} = ObjectStore.put(store, blob)

      tree = Tree.new([{"100644", "hello.txt", blob_sha}])
      {:ok, tree_sha, store} = ObjectStore.put(store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "Exgit Test <test@exgit> 1700000000 +0000",
          committer: "Exgit Test <test@exgit> 1700000000 +0000",
          message: "exgit → real git smoketest\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)
      {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), branch, commit_sha, [])

      repo = %Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      try do
        assert {:ok, _} = Exgit.push(repo, transport(), refspecs: [branch])

        clone_dir =
          Path.join(
            System.tmp_dir!(),
            "exgit_github_clone_#{System.unique_integer([:positive])}"
          )

        File.rm_rf!(clone_dir)

        pat = System.get_env("GITHUB_PAT")
        basic = Base.encode64("x-access-token:#{pat}")

        {out, status} =
          System.cmd(
            "git",
            [
              "-c",
              "http.extraheader=Authorization: Basic #{basic}",
              "clone",
              "--branch",
              branch_name,
              "--depth",
              "1",
              @repo_url <> ".git",
              clone_dir
            ],
            stderr_to_stdout: true
          )

        assert status == 0, "git clone failed:\n#{out}"
        assert File.read!(Path.join(clone_dir, "hello.txt")) == content

        {out, status} = RealGit.git!(clone_dir, ["fsck", "--full"], allow_error: true)
        assert status == 0, "git fsck failed:\n#{out}"

        File.rm_rf!(clone_dir)
      after
        cleanup_branch(branch)
      end
    end

    test "5 random trees push → clone → verify" do
      for iter <- 1..5 do
        branch = unique_branch()

        tree_spec =
          for i <- 1..(2 + :rand.uniform(5)), into: %{} do
            {"f_#{iter}_#{i}.txt", :crypto.strong_rand_bytes(128 + :rand.uniform(512))}
          end

        store = ObjectStore.Memory.new()

        {entries, store} =
          Enum.reduce(tree_spec, {[], store}, fn {name, bytes}, {acc, s} ->
            {:ok, sha, s} = ObjectStore.put(s, Blob.new(bytes))
            {[{"100644", name, sha} | acc], s}
          end)

        {:ok, tree_sha, store} = ObjectStore.put(store, Tree.new(entries))

        commit =
          Commit.new(
            tree: tree_sha,
            parents: [],
            author: "Exgit Fuzz <f@exgit> 1700000000 +0000",
            committer: "Exgit Fuzz <f@exgit> 1700000000 +0000",
            message: "fuzz iter #{iter}\n"
          )

        {:ok, commit_sha, store} = ObjectStore.put(store, commit)
        {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), branch, commit_sha, [])

        repo = %Repository{
          object_store: store,
          ref_store: ref_store,
          config: Exgit.Config.new(),
          path: nil
        }

        try do
          assert {:ok, _} = Exgit.push(repo, transport(), refspecs: [branch])

          {:ok, clone} = Exgit.clone(transport(), lazy: true)

          repo_for_read =
            Enum.reduce(tree_spec, clone, fn {name, expected}, r ->
              assert {:ok, {_, blob}, r} = Exgit.FS.read_path(r, branch, name)

              assert blob.data == expected,
                     "iter=#{iter}: content mismatch at #{name}"

              r
            end)

          _ = repo_for_read
        after
          cleanup_branch(branch)
        end
      end
    end
  end
end
