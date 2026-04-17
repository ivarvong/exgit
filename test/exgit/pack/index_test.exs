defmodule Exgit.Pack.IndexTest do
  use ExUnit.Case, async: true

  alias Exgit.Pack.{Index, Writer, Reader}
  alias Exgit.Object.Blob

  describe "write/2 and read/1" do
    test "round-trips entries" do
      blob1 = Blob.new("hello\n")
      blob2 = Blob.new("world\n")
      pack = Writer.build([blob1, blob2])
      {:ok, parsed} = Reader.parse(pack)

      pack_checksum = binary_part(pack, byte_size(pack) - 20, 20)

      entries =
        Enum.map(parsed, fn {_type, sha, _content} ->
          {sha, :erlang.crc32("placeholder"), 42}
        end)

      idx = Index.write(entries, pack_checksum)
      assert {:ok, read_entries, ^pack_checksum} = Index.read(idx)
      assert length(read_entries) == length(entries)

      read_shas = Enum.map(read_entries, &elem(&1, 0)) |> MapSet.new()
      orig_shas = Enum.map(entries, &elem(&1, 0)) |> MapSet.new()
      assert MapSet.equal?(read_shas, orig_shas)
    end

    test "lookup finds correct offset" do
      sha1 = :crypto.hash(:sha, "obj1")
      sha2 = :crypto.hash(:sha, "obj2")
      pack_checksum = :crypto.hash(:sha, "pack")

      entries = [
        {sha1, 12345, 100},
        {sha2, 67890, 200}
      ]

      idx = Index.write(entries, pack_checksum)
      assert {:ok, 100} = Index.lookup(idx, sha1)
      assert {:ok, 200} = Index.lookup(idx, sha2)
      assert :error = Index.lookup(idx, :crypto.hash(:sha, "missing"))
    end
  end

  describe "git compatibility" do
    @tag :git_cross_check
    test "our index matches git index-pack output" do
      blob = Blob.new("index test content\n")
      pack = Writer.build([blob])

      tmp = Path.join(System.tmp_dir!(), "exgit_idx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      pack_path = Path.join(tmp, "test.pack")
      File.write!(pack_path, pack)

      {_, 0} = System.cmd("git", ["index-pack", pack_path], cd: tmp, stderr_to_stdout: true)

      git_idx = File.read!(Path.join(tmp, "test.idx"))
      assert {:ok, git_entries, _} = Index.read(git_idx)
      assert length(git_entries) == 1

      [{sha, _crc, _offset}] = git_entries
      assert sha == Blob.sha(blob)

      File.rm_rf!(tmp)
    end
  end
end
