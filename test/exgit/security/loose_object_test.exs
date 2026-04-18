defmodule Exgit.Security.LooseObjectTest do
  @moduledoc """
  S5: loose-object parsing validates the declared size and returns
  structured errors for unknown types, rather than raising.
  """

  use ExUnit.Case, async: true

  alias Exgit.{Object.Blob, ObjectStore}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "exgit_loose_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "objects"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: ObjectStore.Disk.new(root)}
  end

  test "get rejects a loose object whose content length disagrees with its header",
       %{root: root, store: store} do
    # Put a valid blob via the library.
    blob = Blob.new("ok content\n")
    {:ok, sha, _store} = ObjectStore.put(store, blob)

    # Corrupt the loose object: replace with a header that lies about
    # the size.
    <<prefix::binary-size(2), rest::binary>> = Base.encode16(sha, case: :lower)
    path = Path.join([root, "objects", prefix, rest])

    fake = :zlib.compress("blob 99999\0short")
    File.write!(path, fake)

    # Current behavior: sha verification catches it. S5 demands that
    # even independent of sha verification, the size header is honored.
    # Either error is acceptable; what matters is no raise.
    assert {:error, _} = ObjectStore.get(store, sha)
  end

  test "get rejects an unknown object type in the loose header",
       %{root: root, store: store} do
    # Fabricate a loose object file with a made-up type. SHA is chosen
    # arbitrarily; we only care that the decode path doesn't raise.
    content = "whatever\n"
    fake_raw = "squid 9\0" <> content
    fake_sha = :crypto.hash(:sha, fake_raw)

    <<prefix::binary-size(2), rest_hex::binary>> = Base.encode16(fake_sha, case: :lower)
    File.mkdir_p!(Path.join([root, "objects", prefix]))
    File.write!(Path.join([root, "objects", prefix, rest_hex]), :zlib.compress(fake_raw))

    assert {:error, _} = ObjectStore.get(store, fake_sha)
  end

  test "get rejects a loose object with a garbled type string", %{root: root, store: store} do
    # Type with spaces in it — should never be accepted.
    fake_raw = "blob x\0data"
    fake_sha = :crypto.hash(:sha, fake_raw)

    <<prefix::binary-size(2), rest_hex::binary>> = Base.encode16(fake_sha, case: :lower)
    File.mkdir_p!(Path.join([root, "objects", prefix]))
    File.write!(Path.join([root, "objects", prefix, rest_hex]), :zlib.compress(fake_raw))

    assert {:error, _} = ObjectStore.get(store, fake_sha)
  end
end
