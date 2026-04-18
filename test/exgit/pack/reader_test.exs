defmodule Exgit.Pack.ReaderTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.Pack.{Reader, Writer}

  describe "parse/1 with base objects" do
    test "parses a single blob" do
      blob = Blob.new("hello\n")
      pack = Writer.build([blob])

      assert {:ok, [{:blob, _sha, "hello\n"}]} = Reader.parse(pack)
    end

    test "parses multiple objects" do
      objects = for i <- 1..10, do: Blob.new("blob #{i}\n")
      pack = Writer.build(objects)

      assert {:ok, parsed} = Reader.parse(pack)
      assert length(parsed) == 10
      assert Enum.all?(parsed, fn {type, _, _} -> type == :blob end)
    end

    test "rejects corrupted checksum" do
      pack = Writer.build([Blob.new("x")])
      corrupted = binary_part(pack, 0, byte_size(pack) - 1) <> <<0>>
      assert {:error, :checksum_mismatch} = Reader.parse(corrupted)
    end
  end

  describe "parse/1 with delta objects from real git" do
    @tag :git_cross_check
    @tag timeout: 30_000
    test "resolves deltas from a git-generated packfile" do
      tmp = Path.join(System.tmp_dir!(), "exgit_delta_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      System.cmd("git", ["init", tmp], stderr_to_stdout: true)
      System.cmd("git", ["-C", tmp, "config", "user.email", "t@t.com"])
      System.cmd("git", ["-C", tmp, "config", "user.name", "Test"])

      # Create commits with similar content to encourage deltas
      for i <- 1..5 do
        content = Enum.map_join(1..20, "\n", fn line -> "line #{line} version #{i}" end) <> "\n"
        File.write!(Path.join(tmp, "file.txt"), content)
        System.cmd("git", ["-C", tmp, "add", "file.txt"])
        System.cmd("git", ["-C", tmp, "commit", "-m", "commit #{i}"])
      end

      # Repack to create a packfile with deltas
      System.cmd("git", ["-C", tmp, "repack", "-a", "-d", "--window=10", "--depth=50"],
        stderr_to_stdout: true
      )

      pack_dir = Path.join([tmp, ".git", "objects", "pack"])
      {:ok, files} = File.ls(pack_dir)
      pack_file = Enum.find(files, &String.ends_with?(&1, ".pack"))

      if pack_file do
        pack_data = File.read!(Path.join(pack_dir, pack_file))
        assert {:ok, objects} = Reader.parse(pack_data)
        assert objects != []

        # Verify every parsed object matches git cat-file
        for {type, sha, _content} <- objects do
          hex = Base.encode16(sha, case: :lower)
          {git_type, 0} = System.cmd("git", ["-C", tmp, "cat-file", "-t", hex])
          assert String.trim(git_type) == Atom.to_string(type)
        end
      end

      File.rm_rf!(tmp)
    end
  end
end
