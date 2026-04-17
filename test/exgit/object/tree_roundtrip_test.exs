defmodule Exgit.Object.TreeRoundtripTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Tree

  # Build raw tree bytes for a canonical tree with one entry per (mode,name,sha)
  # entries passed in sorted order.
  defp raw_tree(entries) do
    entries
    |> Enum.map(fn {mode, name, sha} ->
      sha_bin = if byte_size(sha) == 20, do: sha, else: Base.decode16!(sha, case: :mixed)
      [mode, ?\s, name, 0, sha_bin]
    end)
    |> IO.iodata_to_binary()
  end

  describe "decode |> encode is byte-exact (P0.4)" do
    test "normal 100644 + 100755 entries round-trip" do
      sha1 = :binary.copy(<<1>>, 20)
      sha2 = :binary.copy(<<2>>, 20)

      raw = raw_tree([{"100644", "a.txt", sha1}, {"100755", "run.sh", sha2}])

      {:ok, tree} = Tree.decode(raw)
      assert IO.iodata_to_binary(Tree.encode(tree)) == raw
    end

    test "legacy 100664 mode must NOT be silently rewritten to 100644" do
      # This has been observed in the wild (older git versions, some
      # cross-platform tooling). Rewriting it during decode would change
      # the tree's SHA on re-encode and silently corrupt repositories.
      sha1 = :binary.copy(<<1>>, 20)
      raw = raw_tree([{"100664", "a.txt", sha1}])

      {:ok, tree} = Tree.decode(raw)
      re_encoded = IO.iodata_to_binary(Tree.encode(tree))

      assert re_encoded == raw,
             "decode|>encode changed the bytes of a 100664 entry — SHA will not match"
    end

    test "submodule (160000) entry round-trips" do
      sha1 = :binary.copy(<<3>>, 20)
      raw = raw_tree([{"160000", "sub", sha1}])

      {:ok, tree} = Tree.decode(raw)
      assert IO.iodata_to_binary(Tree.encode(tree)) == raw
    end

    test "symlink (120000) entry round-trips" do
      sha1 = :binary.copy(<<4>>, 20)
      raw = raw_tree([{"120000", "link", sha1}])

      {:ok, tree} = Tree.decode(raw)
      assert IO.iodata_to_binary(Tree.encode(tree)) == raw
    end

    test "directory (40000) entry round-trips" do
      sha1 = :binary.copy(<<5>>, 20)
      raw = raw_tree([{"40000", "dir", sha1}])

      {:ok, tree} = Tree.decode(raw)
      assert IO.iodata_to_binary(Tree.encode(tree)) == raw
    end
  end

  describe "real git cross-check (P0.4 + G.1)" do
    @tag :real_git
    test "a real tree produced by git mktree round-trips byte-for-byte through exgit" do
      alias Exgit.Test.RealGit

      repo = RealGit.init_bare!(RealGit.tmp_dir!())

      blob_sha = RealGit.write_blob!(repo, "hello\n")
      tree_sha = RealGit.write_tree!(repo, [{"100644", "hello.txt", blob_sha}])

      # Get the raw tree object bytes by inflating the loose object.
      loose = RealGit.read_loose!(repo, tree_sha)
      inflated = :zlib.uncompress(loose)

      # Strip the "tree <size>\0" header.
      {pos, 1} = :binary.match(inflated, <<0>>)
      <<_header::binary-size(pos), 0, content::binary>> = inflated

      {:ok, tree} = Exgit.Object.Tree.decode(content)
      assert IO.iodata_to_binary(Exgit.Object.Tree.encode(tree)) == content

      File.rm_rf!(repo)
    end
  end
end
