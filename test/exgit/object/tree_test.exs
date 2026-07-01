defmodule Exgit.Object.TreeTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.Object.Tree
  import Exgit.Test.GitHelper

  describe "new/1" do
    test "sorts entries by name (files), appending / for dirs" do
      blob_sha = Blob.sha(Blob.new("x"))

      tree =
        Tree.new([
          {"100644", "b.txt", blob_sha},
          {"40000", "a", blob_sha},
          {"100644", "a.txt", blob_sha}
        ])

      names = Enum.map(tree.entries, fn {_, name, _} -> name end)
      assert names == ["a.txt", "a", "b.txt"]
    end
  end

  describe "encode/decode round-trip" do
    test "round-trips a simple tree" do
      sha = :crypto.hash(:sha, "test")

      tree =
        Tree.new([
          {"100644", "file.txt", sha},
          {"40000", "dir", sha}
        ])

      encoded = tree |> Tree.encode() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Tree.decode(encoded)
      assert decoded.entries == tree.entries
    end

    test "decode preserves exact mode bytes (normalization happens only in new/1)" do
      sha = :crypto.hash(:sha, "test")
      raw = IO.iodata_to_binary(["100744", " ", "script.sh", <<0>>, sha])
      assert {:ok, decoded} = Tree.decode(raw)
      [{mode, _, _}] = decoded.entries
      # Decode is byte-exact — normalization would break SHA stability.
      assert mode == "100744"
    end

    test "new/1 normalizes executable bit to 100755 and non-exec to 100644" do
      sha = :crypto.hash(:sha, "test")

      exec = Tree.new([{"100744", "x", sha}])
      [{mode, _, _}] = exec.entries
      assert mode == "100755"

      non_exec = Tree.new([{"100640", "y", sha}])
      [{mode, _, _}] = non_exec.entries
      assert mode == "100644"
    end
  end

  describe "canonical_mode/1 with zero-padded modes" do
    test "padded modes canonicalize to their file type, not to a blob mode" do
      # Regression: these used to fall through to the exec-bit coercion
      # and come back as "100644"/"100755", turning dirs into files.
      assert Tree.canonical_mode("040000") == "40000"
      assert Tree.canonical_mode("0120000") == "120000"
      assert Tree.canonical_mode("0160000") == "160000"
      assert Tree.canonical_mode("0100644") == "100644"
      assert Tree.canonical_mode("0100755") == "100755"
    end

    test "strict mode still raises on zero-padded modes" do
      assert_raise ArgumentError, fn -> Tree.canonical_mode("040000", true) end
    end

    test "new/1 with padded modes matches canonical modes, round-trips, stable SHA" do
      sha = :binary.copy(<<0xAB>>, 20)

      padded =
        Tree.new([
          {"040000", "dir", sha},
          {"0120000", "link", sha},
          {"0160000", "sub", sha},
          {"0100644", "file", sha}
        ])

      canonical =
        Tree.new([
          {"40000", "dir", sha},
          {"120000", "link", sha},
          {"160000", "sub", sha},
          {"100644", "file", sha}
        ])

      assert padded.entries == canonical.entries

      encoded = padded |> Tree.encode() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Tree.decode(encoded)
      assert decoded.entries == padded.entries

      # Pinned against `git mktree --missing` fed the same four entries.
      assert Tree.sha_hex(padded) == "93a9f977c0cdaecda57e0ec64d9a5adba8f92e1c"
    end
  end

  describe "sha/1" do
    @tag :git_cross_check
    test "matches git mktree" do
      blob_data = "hello\n"
      blob = Blob.new(blob_data)
      blob_sha_hex = Blob.sha_hex(blob)

      tree = Tree.new([{"100644", "hello.txt", Blob.sha(blob)}])
      our_sha = Tree.sha_hex(tree)

      tmp = System.tmp_dir!()
      repo = Path.join(tmp, "exgit_tree_test_#{System.unique_integer([:positive])}")
      System.cmd("git", ["init", "--bare", "--initial-branch=main", "-q", repo])

      {_, 0} = cmd_with_stdin("git", ["hash-object", "-w", "--stdin"], blob_data, cd: repo)

      tree_input = "100644 blob #{blob_sha_hex}\thello.txt\n"
      {git_sha, 0} = cmd_with_stdin("git", ["mktree"], tree_input, cd: repo)

      assert our_sha == String.trim(git_sha)
      File.rm_rf!(repo)
    end
  end
end
