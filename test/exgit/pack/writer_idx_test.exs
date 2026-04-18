defmodule Exgit.Pack.WriterIdxTest do
  @moduledoc """
  Pack.Writer can emit both a .pack and a .idx that round-trips
  through Pack.Index.lookup/2.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.Pack.{Index, Writer}

  test "build_with_index returns {pack_bytes, idx_bytes} that round-trip" do
    blobs =
      for i <- 1..10, do: Blob.new("content #{i}\n" <> :crypto.strong_rand_bytes(64))

    {pack, idx} = Writer.build_with_index(blobs)

    # The pack itself is verifiable.
    assert <<"PACK", _::binary>> = pack
    assert byte_size(idx) > 1024

    # Every blob's sha is present in the idx.
    for blob <- blobs do
      assert {:ok, _offset} = Index.lookup(idx, Blob.sha(blob))
    end

    # A non-existent sha returns :error.
    assert :error = Index.lookup(idx, :crypto.hash(:sha, "never used"))
  end

  test "idx offsets correctly point at each object's position in the pack" do
    blobs = for i <- 1..5, do: Blob.new("b#{i}\n")
    {pack, idx} = Writer.build_with_index(blobs)

    for blob <- blobs do
      sha = Blob.sha(blob)
      {:ok, offset} = Index.lookup(idx, sha)

      # Parse the object at that offset and confirm it matches.
      assert {:ok, {:blob, ^sha, _content}} = Exgit.Pack.Reader.parse_at(pack, offset)
    end
  end

  @tag :real_git
  test "generated idx is byte-compatible with git verify-pack" do
    blobs = for i <- 1..5, do: Blob.new("rg-#{i}\n")
    {pack, idx} = Writer.build_with_index(blobs)

    tmp = Path.join(System.tmp_dir!(), "exgit_widx_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    pack_path = Path.join(tmp, "pack-abc.pack")
    idx_path = Path.join(tmp, "pack-abc.idx")
    File.write!(pack_path, pack)
    File.write!(idx_path, idx)

    {out, status} =
      System.cmd("git", ["verify-pack", "-v", pack_path], stderr_to_stdout: true)

    assert status == 0, "git verify-pack rejected our idx:\n#{out}"

    File.rm_rf!(tmp)
  end
end
