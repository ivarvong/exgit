defmodule Exgit.WritePathHardeningTest do
  @moduledoc """
  Write-path hardening: byte-equivalence tests vs real `git` for
  the exact bytes of encoded objects, plus randomized commit
  graphs including merges.

  Complements `roundtrip_smoketest_test.exs` and
  `real_git_integration_test.exs`:

    * `real_git_integration_test` asserts **SHA** parity for
      single blobs/trees/commits (good — proves equivalent
      hashing).
    * `roundtrip_smoketest` asserts content parity after a
      push/clone roundtrip (good — proves network/pack layer).
    * This file fills two gaps:
        1. **Byte-for-byte encode parity** — exgit's
           `Object.encode/1` produces the exact bytes `git
           cat-file` emits, not just a semantically-equivalent
           encoding that happens to hash the same.
        2. **Multi-parent (merge) commits** — the existing
           suite's random graphs are all linear.

  Tagged `:real_git` + `:slow` consistent with the rest of the
  real-git suite.
  """

  use ExUnit.Case, async: false

  @moduletag :real_git
  @moduletag :slow

  alias Exgit.Object.{Blob, Commit, Tree}
  alias Exgit.Test.RealGit

  setup do
    repo = RealGit.init_bare!(RealGit.tmp_dir!("exgit_wp_hard"))
    on_exit(fn -> File.rm_rf!(repo) end)
    %{repo: repo}
  end

  describe "byte-equivalence: Object.encode/1 produces git's canonical bytes" do
    test "random blob encodes identically", %{repo: repo} do
      for size <- [0, 1, 127, 1024, 65_536, 1_048_576] do
        data = :crypto.strong_rand_bytes(size)
        sha_hex = RealGit.write_blob!(repo, data)
        git_bytes = cat_file_raw(repo, sha_hex)

        # Git's on-disk loose object is `"blob <size>\0<content>"`;
        # exgit's Object.encode/1 returns just the content (no header).
        # We compare just the content portion. SHA parity is
        # already tested in real_git_integration_test.
        exgit_content = Blob.new(data) |> Exgit.Object.encode() |> IO.iodata_to_binary()
        git_content = strip_header(git_bytes)

        assert exgit_content == git_content,
               "blob encode divergence at size=#{size}"
      end
    end

    test "random tree encodes identically (entries in canonical git order)",
         %{repo: repo} do
      # git mktree sorts by name (with trailing / for directories).
      # Exgit's Tree.encode/1 MUST produce the same byte order
      # regardless of caller's input ordering.
      blob_shas =
        for i <- 1..5 do
          {RealGit.write_blob!(repo, "content #{i}\n"), i}
        end

      entries =
        for {sha_hex, i} <- blob_shas do
          mode = Enum.random(["100644", "100755"])
          name = "f_#{i}"
          {mode, name, sha_hex}
        end

      # Shuffle so our input order differs from git's expected canonical.
      shuffled = Enum.shuffle(entries)

      git_tree_sha = RealGit.write_tree!(repo, entries)
      git_tree_bytes = cat_file_raw(repo, git_tree_sha) |> strip_header()

      exgit_entries =
        for {mode, name, sha_hex} <- shuffled do
          {mode, name, RealGit.hex_to_bin(sha_hex)}
        end

      exgit_tree = Tree.new(exgit_entries)
      exgit_bytes = Tree.encode(exgit_tree) |> IO.iodata_to_binary()

      assert exgit_bytes == git_tree_bytes,
             "tree encode divergence (input was shuffled, canonical order mandatory)"
    end

    test "tree with mixed blob + subtree entries encodes identically",
         %{repo: repo} do
      b_sha = RealGit.write_blob!(repo, "hello\n")
      sub_tree_sha = RealGit.write_tree!(repo, [{"100644", "inner.txt", b_sha}])

      # A tree mixing blobs (100644) and trees (40000). RealGit's
      # `write_tree!` helper hardcodes `blob` in the mktree input;
      # for this mixed-type case we drive `git mktree` directly so
      # we can specify `tree` for the subtree entry.
      mkfile =
        "100644 blob #{b_sha}\treadme.md\n" <>
          "40000 tree #{sub_tree_sha}\tsubdir\n"

      {out, _} = RealGit.git_stdin!(repo, ["mktree"], mkfile)
      git_tree_sha = String.trim(out)
      git_bytes = cat_file_raw(repo, git_tree_sha) |> strip_header()

      exgit_tree =
        Tree.new([
          {"100644", "readme.md", RealGit.hex_to_bin(b_sha)},
          {"40000", "subdir", RealGit.hex_to_bin(sub_tree_sha)}
        ])

      exgit_bytes = Tree.encode(exgit_tree) |> IO.iodata_to_binary()

      assert exgit_bytes == git_bytes
    end

    test "commit (single parent) encodes identically", %{repo: repo} do
      b_sha = RealGit.write_blob!(repo, "body\n")
      t_sha_hex = RealGit.write_tree!(repo, [{"100644", "a", b_sha}])

      # Parent commit.
      parent_sha = RealGit.commit_tree!(repo, tree: t_sha_hex, message: "parent\n")

      message = "child commit\n\nLonger body.\n"

      # Real git's commit-tree (using RealGit's helper, which sets
      # fixed author/committer/date env) produces the canonical
      # bytes we need to match.
      git_commit_sha =
        RealGit.commit_tree!(
          repo,
          tree: t_sha_hex,
          parents: [parent_sha],
          message: message
        )

      git_bytes = cat_file_raw(repo, git_commit_sha) |> strip_header()

      # Build the equivalent exgit commit with the SAME author /
      # committer / date that RealGit.git_stdin! sets via env.
      exgit_commit =
        Commit.new(
          tree: RealGit.hex_to_bin(t_sha_hex),
          parents: [RealGit.hex_to_bin(parent_sha)],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: message
        )

      exgit_bytes = Exgit.Object.encode(exgit_commit) |> IO.iodata_to_binary()

      assert exgit_bytes == git_bytes, """
      Commit byte divergence.

      git:
      #{inspect(git_bytes, limit: 1000)}

      exgit:
      #{inspect(exgit_bytes, limit: 1000)}
      """
    end

    test "merge commit (two parents) encodes identically", %{repo: repo} do
      # Build two divergent branches that share a common ancestor,
      # then merge. Verify merge commit encodes byte-identically.
      b_sha = RealGit.write_blob!(repo, "base\n")
      base_tree = RealGit.write_tree!(repo, [{"100644", "a", b_sha}])
      base_commit = RealGit.commit_tree!(repo, tree: base_tree, message: "base\n")

      # Two "branches" that both descend from base.
      b1 = RealGit.write_blob!(repo, "branch1\n")
      t1 = RealGit.write_tree!(repo, [{"100644", "a", b1}])
      c1 = RealGit.commit_tree!(repo, tree: t1, parents: [base_commit], message: "b1\n")

      b2 = RealGit.write_blob!(repo, "branch2\n")
      t2 = RealGit.write_tree!(repo, [{"100644", "a", b2}])
      c2 = RealGit.commit_tree!(repo, tree: t2, parents: [base_commit], message: "b2\n")

      # Merge tree — arbitrary resolution (we just need a valid tree).
      mb = RealGit.write_blob!(repo, "merged\n")
      mt = RealGit.write_tree!(repo, [{"100644", "a", mb}])

      git_merge_sha =
        RealGit.commit_tree!(
          repo,
          tree: mt,
          parents: [c1, c2],
          message: "Merge branches\n"
        )

      git_bytes = cat_file_raw(repo, git_merge_sha) |> strip_header()

      exgit_merge =
        Commit.new(
          tree: RealGit.hex_to_bin(mt),
          parents: [RealGit.hex_to_bin(c1), RealGit.hex_to_bin(c2)],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: "Merge branches\n"
        )

      exgit_bytes = Exgit.Object.encode(exgit_merge) |> IO.iodata_to_binary()

      assert exgit_bytes == git_bytes
    end

    test "octopus merge (three parents) encodes identically", %{repo: repo} do
      # Git supports N-parent merges (octopus). Exgit must emit one
      # `parent ` header per parent in the given order.
      b = RealGit.write_blob!(repo, "b\n")
      t = RealGit.write_tree!(repo, [{"100644", "f", b}])

      p1 = RealGit.commit_tree!(repo, tree: t, message: "p1\n")
      p2 = RealGit.commit_tree!(repo, tree: t, message: "p2\n")
      p3 = RealGit.commit_tree!(repo, tree: t, message: "p3\n")

      git_merge =
        RealGit.commit_tree!(repo,
          tree: t,
          parents: [p1, p2, p3],
          message: "Octopus merge\n"
        )

      git_bytes = cat_file_raw(repo, git_merge) |> strip_header()

      exgit_merge =
        Commit.new(
          tree: RealGit.hex_to_bin(t),
          parents: [
            RealGit.hex_to_bin(p1),
            RealGit.hex_to_bin(p2),
            RealGit.hex_to_bin(p3)
          ],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: "Octopus merge\n"
        )

      exgit_bytes = Exgit.Object.encode(exgit_merge) |> IO.iodata_to_binary()

      assert exgit_bytes == git_bytes
    end
  end

  describe "randomized graphs with merges" do
    test "push a DAG with a merge commit, round-trip cleanly", %{repo: repo} do
      # Build via exgit: base → (branch1, branch2) → merge.
      store = Exgit.ObjectStore.Disk.new(repo)

      {:ok, blob_sha, store} = Exgit.ObjectStore.put(store, Blob.new("initial\n"))
      tree = Tree.new([{"100644", "f", blob_sha}])
      {:ok, tree_sha, store} = Exgit.ObjectStore.put(store, tree)

      base =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: "base\n"
        )

      {:ok, base_sha, store} = Exgit.ObjectStore.put(store, base)

      # Branch 1.
      {:ok, b1_sha, store} = Exgit.ObjectStore.put(store, Blob.new("b1\n"))
      t1 = Tree.new([{"100644", "f", b1_sha}])
      {:ok, t1_sha, store} = Exgit.ObjectStore.put(store, t1)

      c1 =
        Commit.new(
          tree: t1_sha,
          parents: [base_sha],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: "c1\n"
        )

      {:ok, c1_sha, store} = Exgit.ObjectStore.put(store, c1)

      # Branch 2.
      {:ok, b2_sha, store} = Exgit.ObjectStore.put(store, Blob.new("b2\n"))
      t2 = Tree.new([{"100644", "f", b2_sha}])
      {:ok, t2_sha, store} = Exgit.ObjectStore.put(store, t2)

      c2 =
        Commit.new(
          tree: t2_sha,
          parents: [base_sha],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: "c2\n"
        )

      {:ok, c2_sha, store} = Exgit.ObjectStore.put(store, c2)

      # Merge.
      {:ok, mb_sha, store} = Exgit.ObjectStore.put(store, Blob.new("merged\n"))
      mt = Tree.new([{"100644", "f", mb_sha}])
      {:ok, mt_sha, store} = Exgit.ObjectStore.put(store, mt)

      merge =
        Commit.new(
          tree: mt_sha,
          parents: [c1_sha, c2_sha],
          author: "Ex Git <ex@git.test> 946684800 +0000",
          committer: "Ex Git <ex@git.test> 946684800 +0000",
          message: "Merge\n"
        )

      {:ok, merge_sha, _store} = Exgit.ObjectStore.put(store, merge)

      # Verify the merge commit is parseable by real git.
      merge_hex = Base.encode16(merge_sha, case: :lower)
      {out, 0} = RealGit.git!(repo, ["cat-file", "-p", merge_hex])

      # Check the merge commit has two parent headers in git's view.
      parent_count =
        out
        |> String.split("\n")
        |> Enum.count(&String.starts_with?(&1, "parent "))

      assert parent_count == 2, "expected 2 parents, got #{parent_count}\n#{out}"

      # Run fsck to verify the full graph is consistent.
      {fsck_out, status} = RealGit.git!(repo, ["fsck", "--no-dangling"], allow_error: true)

      assert status == 0,
             "git fsck failed:\n#{fsck_out}"
    end
  end

  describe "large blob byte-equivalence" do
    test "1 MiB random blob", %{repo: repo} do
      data = :crypto.strong_rand_bytes(1_048_576)
      sha_hex = RealGit.write_blob!(repo, data)

      exgit_sha = Blob.sha_hex(Blob.new(data))

      assert exgit_sha == sha_hex

      # Byte parity on the decompressed content.
      git_bytes = cat_file_raw(repo, sha_hex) |> strip_header()
      exgit_bytes = Blob.new(data) |> Exgit.Object.encode() |> IO.iodata_to_binary()

      assert exgit_bytes == git_bytes
      assert byte_size(exgit_bytes) == 1_048_576
    end

    test "blob with all-zero bytes (known-tricky for some encoders)",
         %{repo: repo} do
      data = :binary.copy(<<0>>, 4096)
      sha_hex = RealGit.write_blob!(repo, data)
      exgit_sha = Blob.sha_hex(Blob.new(data))
      assert exgit_sha == sha_hex
    end

    test "blob with UTF-8 multibyte chars", %{repo: repo} do
      # git treats blobs as opaque bytes; no encoding conversion. Verify.
      data = String.duplicate("héllo wörld 🌍\n", 100)
      sha_hex = RealGit.write_blob!(repo, data)
      exgit_sha = Blob.sha_hex(Blob.new(data))
      assert exgit_sha == sha_hex
    end
  end

  # --- Helpers ---

  # Read the raw on-disk bytes of a loose object, zlib-decompress,
  # and return them. Returns `"<type> <size>\0<content>"`.
  defp cat_file_raw(repo, sha_hex) do
    raw = RealGit.read_loose!(repo, sha_hex)
    :zlib.uncompress(raw)
  end

  # Strip the git header prefix to get just the content.
  # Format: "<type> <size>\0<content>".
  defp strip_header(bytes) do
    {pos, 1} = :binary.match(bytes, <<0>>)
    <<_::binary-size(pos), 0, content::binary>> = bytes
    content
  end
end
