defmodule Exgit.RoundtripSmoketest do
  @moduledoc """
  End-to-end roundtrip smoketest.

  Strategy: every test generates a **random** file tree, roundtrips it
  through exgit against a real bare git repo, and cross-checks against
  the real `git` CLI.

  What we prove:

    1. `real git push` → `exgit.clone` → byte-for-byte content match.
    2. `exgit.push` → `git cat-file` → every object decodes identically.
    3. `exgit.push` → `git fsck` → no integrity errors.
    4. `exgit.push` → `git clone` → working tree identical to what we
       pushed (fuzz-style: random trees of varying depth / size).
    5. SHA stability: for every blob, tree, and commit written by
       exgit, the SHA matches what `git hash-object` / `git mktree` /
       `git commit-tree` computes for the same bytes.

  Tagged `:real_git` (needs git on PATH) and `:slow` (generates random
  trees with up to a few hundred files).
  """

  use ExUnit.Case, async: false

  @moduletag :real_git
  @moduletag :slow

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.{ObjectStore, RefStore, Repository, Transport}
  alias Exgit.Test.RealGit

  # ---- Fixtures ----

  # Random file tree generator. Returns a map of path => bytes.
  defp random_tree(opts) do
    n_files = Keyword.get(opts, :n_files, 20)
    max_depth = Keyword.get(opts, :max_depth, 3)
    max_size = Keyword.get(opts, :max_size, 4096)

    for _ <- 1..n_files, into: %{} do
      {random_path(max_depth), random_bytes(max_size)}
    end
  end

  defp random_path(max_depth) do
    depth = :rand.uniform(max_depth + 1) - 1

    segments =
      for _ <- 0..depth do
        len = 3 + :rand.uniform(7)
        for _ <- 1..len, into: "", do: <<Enum.random(?a..?z)>>
      end

    ext = Enum.random(["ex", "exs", "md", "txt", "json"])
    Path.join(segments ++ ["file.#{ext}"])
  end

  defp random_bytes(max_size) do
    size = :rand.uniform(max_size)
    :crypto.strong_rand_bytes(size)
  end

  # ---- Helpers ----

  defp tmp_dir!(prefix) do
    base =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(base)
    base
  end

  # Populate a working directory with the given path => bytes map,
  # add + commit via real git. Returns {commit_sha_hex, dir}.
  defp git_commit_tree!(tree, message \\ "fixture commit") do
    dir = tmp_dir!("exgit_rt_work")
    RealGit.init!(dir)

    for {path, bytes} <- tree do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, bytes)
    end

    # --chmod=... keeps modes predictable; add then commit.
    RealGit.git!(dir, ["add", "-A"])
    RealGit.git!(dir, ["commit", "-m", message, "--allow-empty"])
    {out, _} = RealGit.git!(dir, ["rev-parse", "HEAD"])
    {String.trim(out), dir}
  end

  # ---- Tests ----

  describe "git push → exgit.clone roundtrip" do
    test "random tree pushed by real git is faithfully cloned by exgit" do
      tree = random_tree(n_files: 25, max_depth: 3, max_size: 8192)

      {commit_sha_hex, work_dir} = git_commit_tree!(tree)

      bare = tmp_dir!("exgit_rt_bare")
      RealGit.init_bare!(bare)

      # Push from the working repo to the bare.
      RealGit.git!(work_dir, ["remote", "add", "origin", bare])
      RealGit.git!(work_dir, ["push", "origin", "HEAD:refs/heads/main"])

      # --- exgit clone ---
      t = Transport.File.new(bare)
      {:ok, repo} = Exgit.clone(t)

      # Verify every file in the original tree round-tripped.
      for {path, expected_bytes} <- tree do
        {:ok, {_mode, blob}, _} = Exgit.FS.read_path(repo, "HEAD", path)

        assert blob.data == expected_bytes,
               "content mismatch for #{path}: " <>
                 "expected #{byte_size(expected_bytes)} bytes, got #{byte_size(blob.data)}"
      end

      # Verify no extra files appeared.
      exgit_paths =
        Exgit.FS.walk(repo, "HEAD")
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      expected_paths = Map.keys(tree) |> MapSet.new()
      assert exgit_paths == expected_paths

      # Verify the HEAD commit SHA is exactly what git produced.
      {:ok, head_sha} = RefStore.resolve(repo.ref_store, "HEAD")
      assert Base.encode16(head_sha, case: :lower) == commit_sha_hex

      File.rm_rf!(work_dir)
      File.rm_rf!(bare)
    end

    test "lazy_clone + read_path roundtrip: random file, random path" do
      tree = random_tree(n_files: 50, max_depth: 4, max_size: 2048)

      {_commit_sha_hex, work_dir} = git_commit_tree!(tree)

      bare = tmp_dir!("exgit_rt_bare_lazy")
      RealGit.init_bare!(bare)

      RealGit.git!(work_dir, ["remote", "add", "origin", bare])
      RealGit.git!(work_dir, ["push", "origin", "HEAD:refs/heads/main"])

      t = Transport.File.new(bare)
      {:ok, repo} = Exgit.lazy_clone(t)

      # Pick 5 random paths and verify each reads back correctly.
      sample = Enum.take_random(Map.to_list(tree), 5)

      repo =
        Enum.reduce(sample, repo, fn {path, expected_bytes}, repo ->
          assert {:ok, {_mode, blob}, repo} = Exgit.FS.read_path(repo, "HEAD", path)

          assert blob.data == expected_bytes,
                 "lazy read content mismatch for #{path}"

          repo
        end)

      _ = repo

      File.rm_rf!(work_dir)
      File.rm_rf!(bare)
    end
  end

  describe "exgit.push → git verification roundtrip" do
    test "exgit-built commit passes git fsck and re-clones identically" do
      tree = random_tree(n_files: 15, max_depth: 2, max_size: 4096)

      # Build the tree entirely in exgit.
      store = ObjectStore.Memory.new()

      {store, tree_by_dir} = build_exgit_tree(store, tree)

      root_tree_sha = Map.fetch!(tree_by_dir, "")

      commit =
        Commit.new(
          tree: root_tree_sha,
          parents: [],
          author: "Exgit <ex@git.test> 1700000000 +0000",
          committer: "Exgit <ex@git.test> 1700000000 +0000",
          message: "exgit-authored\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      {:ok, ref_store} =
        RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

      {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      bare = tmp_dir!("exgit_rt_push_target")
      RealGit.init_bare!(bare)

      t = Transport.File.new(bare)
      {:ok, _result} = Exgit.push(repo, t, refspecs: ["refs/heads/main"])

      # --- git verification ---
      # fsck must report a clean tree.
      {out, status} = RealGit.git!(bare, ["fsck", "--full"], allow_error: true)

      assert status == 0, "git fsck failed:\n#{out}"

      # The HEAD sha in the bare repo must match what exgit computed.
      {out, _} = RealGit.git!(bare, ["rev-parse", "refs/heads/main"])
      assert String.trim(out) == Base.encode16(commit_sha, case: :lower)

      # git cat-file every blob — verify each byte matches.
      for {path, expected_bytes} <- tree do
        {out, _} = RealGit.git!(bare, ["cat-file", "-p", "HEAD:#{path}"])
        assert out == expected_bytes, "content mismatch for #{path}"
      end

      File.rm_rf!(bare)
    end

    test "exgit.push then git clone yields the same working tree" do
      tree = random_tree(n_files: 10, max_depth: 2, max_size: 2048)

      store = ObjectStore.Memory.new()
      {store, tree_by_dir} = build_exgit_tree(store, tree)
      root_tree_sha = Map.fetch!(tree_by_dir, "")

      commit =
        Commit.new(
          tree: root_tree_sha,
          parents: [],
          author: "Exgit <ex@git.test> 1700000000 +0000",
          committer: "Exgit <ex@git.test> 1700000000 +0000",
          message: "exgit-push-then-clone\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      {:ok, ref_store} =
        RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

      {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      bare = tmp_dir!("exgit_rt_push_clone")
      RealGit.init_bare!(bare)

      {:ok, _} = Exgit.push(repo, Transport.File.new(bare), refspecs: ["refs/heads/main"])

      # Now clone the bare with real git into a fresh working dir.
      checkout = tmp_dir!("exgit_rt_checkout")
      RealGit.git!(Path.dirname(checkout), ["clone", bare, Path.basename(checkout), "-q"])

      # Every file exists with the right bytes.
      for {path, expected_bytes} <- tree do
        actual = File.read!(Path.join(checkout, path))
        assert actual == expected_bytes, "checkout mismatch for #{path}"
      end

      # Walking the checkout finds exactly our files (minus .git).
      actual_paths =
        Path.wildcard(Path.join(checkout, "**/*"))
        |> Enum.reject(&File.dir?/1)
        |> Enum.reject(&String.contains?(&1, "/.git/"))
        |> Enum.map(&Path.relative_to(&1, checkout))
        |> MapSet.new()

      expected_paths = Map.keys(tree) |> MapSet.new()
      assert actual_paths == expected_paths

      File.rm_rf!(bare)
      File.rm_rf!(checkout)
    end
  end

  describe "property-style fuzz: N random tree shapes" do
    test "20 randomized push+clone roundtrips all match byte-for-byte" do
      for iter <- 1..20 do
        # Vary every knob so we catch shape-dependent bugs.
        n_files = 1 + :rand.uniform(50)
        max_depth = :rand.uniform(6)
        max_size = Enum.random([16, 512, 4096, 65_536])

        tree = random_tree(n_files: n_files, max_depth: max_depth, max_size: max_size)

        {commit_hex, work_dir} = git_commit_tree!(tree, "iter #{iter}")

        bare = tmp_dir!("exgit_rt_fuzz_bare_#{iter}")
        RealGit.init_bare!(bare)

        RealGit.git!(work_dir, ["remote", "add", "origin", bare])
        RealGit.git!(work_dir, ["push", "origin", "HEAD:refs/heads/main"])

        {:ok, repo} = Exgit.clone(Transport.File.new(bare))

        for {path, expected} <- tree do
          {:ok, {_, blob}, _} = Exgit.FS.read_path(repo, "HEAD", path)

          assert blob.data == expected,
                 "iter=#{iter} n_files=#{n_files} max_depth=#{max_depth} max_size=#{max_size}: " <>
                   "mismatch at #{path}"
        end

        {:ok, head_sha} = RefStore.resolve(repo.ref_store, "HEAD")

        assert Base.encode16(head_sha, case: :lower) == commit_hex,
               "iter=#{iter}: commit SHA disagreement with real git"

        File.rm_rf!(work_dir)
        File.rm_rf!(bare)
      end
    end

    test "10 randomized exgit.push → git fsck roundtrips" do
      for iter <- 1..10 do
        n_files = 1 + :rand.uniform(20)
        max_depth = :rand.uniform(4)
        max_size = Enum.random([32, 1024, 8192])

        tree = random_tree(n_files: n_files, max_depth: max_depth, max_size: max_size)

        store = ObjectStore.Memory.new()
        {store, tree_by_dir} = build_exgit_tree(store, tree)
        root_tree_sha = Map.fetch!(tree_by_dir, "")

        commit =
          Commit.new(
            tree: root_tree_sha,
            parents: [],
            author: "Exgit <ex@git.test> 1700000000 +0000",
            committer: "Exgit <ex@git.test> 1700000000 +0000",
            message: "fuzz iter #{iter}\n"
          )

        {:ok, commit_sha, store} = ObjectStore.put(store, commit)

        {:ok, ref_store} =
          RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

        {:ok, ref_store} =
          RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

        repo = %Repository{
          object_store: store,
          ref_store: ref_store,
          config: Exgit.Config.new(),
          path: nil
        }

        bare = tmp_dir!("exgit_rt_fuzz_push_#{iter}")
        RealGit.init_bare!(bare)

        {:ok, _} = Exgit.push(repo, Transport.File.new(bare), refspecs: ["refs/heads/main"])

        {out, status} = RealGit.git!(bare, ["fsck", "--full"], allow_error: true)

        assert status == 0,
               "iter=#{iter} n_files=#{n_files} max_depth=#{max_depth} max_size=#{max_size}: " <>
                 "git fsck failed\n#{out}"

        for {path, expected} <- tree do
          {out, _} = RealGit.git!(bare, ["cat-file", "-p", "HEAD:#{path}"])

          assert out == expected,
                 "iter=#{iter}: content mismatch for #{path}"
        end

        File.rm_rf!(bare)
      end
    end
  end

  describe "SHA stability: exgit SHAs match real git SHAs byte-for-byte" do
    test "hash-object over random blobs" do
      for _ <- 1..10 do
        bytes = :crypto.strong_rand_bytes(:rand.uniform(10_000))

        dir = tmp_dir!("exgit_rt_hashobj")
        RealGit.init_bare!(dir)

        git_sha = RealGit.write_blob!(dir, bytes)

        exgit_sha = Blob.sha_hex(Blob.new(bytes))

        assert exgit_sha == git_sha, "sha mismatch on #{byte_size(bytes)}-byte blob"

        File.rm_rf!(dir)
      end
    end

    test "mktree over random small trees" do
      for _ <- 1..5 do
        dir = tmp_dir!("exgit_rt_mktree")
        RealGit.init_bare!(dir)

        # Make 3-10 blobs.
        n_entries = 3 + :rand.uniform(7)

        entries =
          for i <- 1..n_entries do
            content = :crypto.strong_rand_bytes(128)
            sha_hex = RealGit.write_blob!(dir, content)
            mode = Enum.random(["100644", "100755"])
            {mode, "f_#{i}_#{:rand.uniform(9999)}", sha_hex}
          end

        git_tree_sha = RealGit.write_tree!(dir, entries)

        exgit_entries =
          for {mode, name, sha_hex} <- entries do
            {mode, name, RealGit.hex_to_bin(sha_hex)}
          end

        exgit_tree_sha = Tree.sha_hex(Tree.new(exgit_entries))

        assert exgit_tree_sha == git_tree_sha

        File.rm_rf!(dir)
      end
    end
  end

  # ---- Internal: build a tree of %Tree objects matching a path map ----

  # Given a store and %{path => bytes}, write every blob + construct
  # every subtree, returning {store, %{dir_path => tree_sha}} where
  # `""` keys the root tree.
  defp build_exgit_tree(store, path_map) do
    # Group files by parent directory.
    by_dir =
      path_map
      |> Enum.group_by(fn {path, _} -> Path.dirname(path) |> normalize_dirname() end)
      |> Enum.into(%{})

    # Write every blob first.
    {blob_shas, store} =
      Enum.reduce(path_map, {%{}, store}, fn {path, bytes}, {acc, s} ->
        blob = Blob.new(bytes)
        {:ok, sha, s} = ObjectStore.put(s, blob)
        {Map.put(acc, path, sha), s}
      end)

    # Collect every directory path (including all parents).
    all_dirs =
      path_map
      |> Map.keys()
      |> Enum.flat_map(&all_parent_dirs/1)
      |> Enum.uniq()
      |> Enum.sort_by(&depth/1, :desc)

    # Build trees deepest-first so each parent can embed its children.
    {trees, store} =
      Enum.reduce(all_dirs, {%{}, store}, fn dir, {acc, s} ->
        # Files directly in `dir`.
        file_entries =
          for {path, _bytes} <- Map.get(by_dir, dir, []) do
            {"100644", Path.basename(path), Map.fetch!(blob_shas, path)}
          end

        # Subdirectory entries (immediate children of `dir`).
        subdir_entries =
          for {child_dir, sha} <- acc,
              Path.dirname(child_dir) |> normalize_dirname() == dir do
            {"40000", Path.basename(child_dir), sha}
          end

        entries = file_entries ++ subdir_entries
        {:ok, sha, s} = ObjectStore.put(s, Tree.new(entries))
        {Map.put(acc, dir, sha), s}
      end)

    {store, trees}
  end

  defp normalize_dirname("."), do: ""
  defp normalize_dirname(s), do: s

  defp all_parent_dirs(path) do
    dir = Path.dirname(path) |> normalize_dirname()
    walk_up(dir, [dir])
  end

  defp walk_up("", acc), do: acc

  defp walk_up(dir, acc) do
    parent = Path.dirname(dir) |> normalize_dirname()
    walk_up(parent, [parent | acc])
  end

  defp depth(""), do: 0
  defp depth(dir), do: length(Path.split(dir))
end
