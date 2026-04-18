defmodule Exgit.Security.PartialImportTest do
  @moduledoc """
  S6: ObjectStore.Disk.import_objects must surface per-object failures
  so a half-written pack doesn't silently look like a successful import.
  """

  use ExUnit.Case, async: true

  alias Exgit.{Object.Blob, ObjectStore}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "exgit_partial_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "objects"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: ObjectStore.Disk.new(root)}
  end

  test "import_objects with all valid objects returns :ok", %{store: store} do
    b1 = Blob.new("one")
    b2 = Blob.new("two")

    raw = [
      {:blob, Blob.sha(b1), IO.iodata_to_binary(Blob.encode(b1))},
      {:blob, Blob.sha(b2), IO.iodata_to_binary(Blob.encode(b2))}
    ]

    assert {:ok, _store} = ObjectStore.import_objects(store, raw)
  end

  test "import_objects with a malformed object returns :partial_import", %{store: store} do
    # Valid blob + garbage that can't decode.
    b1 = Blob.new("good")
    good_raw = {:blob, Blob.sha(b1), IO.iodata_to_binary(Blob.encode(b1))}

    # An entry with an unknown type that Object.decode/2 will reject.
    bad_raw = {:unknown_type, :crypto.hash(:sha, "fake"), "garbage"}

    raw = [good_raw, bad_raw]

    assert {:error, {:partial_import, failures}} = ObjectStore.import_objects(store, raw)
    assert is_list(failures) and length(failures) >= 1
  end
end
