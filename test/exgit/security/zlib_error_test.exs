defmodule Exgit.Security.ZlibErrorTest do
  @moduledoc """
  Regression for review finding #3.

  `ObjectStore.Disk.get_object/2` previously called
  `:zlib.uncompress/1` on whatever bytes it read off disk; that
  function RAISES on invalid zlib. The `SECURITY.md` threat model
  explicitly names the on-disk object as a defended boundary ("SHA
  verification on read detects bit-rot and tampering"), so crashing
  before SHA verification can run violates the promise. The fix
  wraps the decompression in a try/rescue returning
  `{:error, :zlib_error}`.
  """

  use ExUnit.Case, async: true

  alias Exgit.{Object.Blob, ObjectStore}

  setup do
    root = Path.join(System.tmp_dir!(), "exgit_zlib_err_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "objects"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: ObjectStore.Disk.new(root)}
  end

  test "get returns {:error, :zlib_error} when loose-object content is garbage",
       %{root: root, store: store} do
    # Put a real blob so we know a legal sha, then overwrite its
    # file with random non-zlib bytes.
    blob = Blob.new("ok\n")
    {:ok, sha, _store} = ObjectStore.put(store, blob)

    <<prefix::binary-size(2), rest::binary>> = Base.encode16(sha, case: :lower)
    path = Path.join([root, "objects", prefix, rest])

    # Random non-zlib bytes. zlib headers start with 0x78 0x9C for
    # default compression; 0x00 0xFF has neither magic nor adler32.
    File.write!(path, <<0, 0xFF, 1, 2, 3, 4, 5>>)

    assert {:error, :zlib_error} = ObjectStore.get(store, sha)
  end

  test "get returns {:error, :zlib_error} on truncated compressed stream",
       %{root: root, store: store} do
    blob = Blob.new("some content\n")
    {:ok, sha, _store} = ObjectStore.put(store, blob)

    <<prefix::binary-size(2), rest::binary>> = Base.encode16(sha, case: :lower)
    path = Path.join([root, "objects", prefix, rest])

    # Read the real compressed stream, truncate it to 3 bytes
    # (definitely incomplete).
    compressed = File.read!(path)
    File.write!(path, binary_part(compressed, 0, 3))

    assert {:error, _} = ObjectStore.get(store, sha)
  end
end
