defmodule Exgit.ObjectStore.DiskDurabilityTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore

  setup do
    root =
      Path.join(System.tmp_dir!(), "exgit_disk_durability_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: ObjectStore.Disk.new(root)}
  end

  describe "object writes (P3.1)" do
    test "writes do not leave .tmp.* files in the object dir", %{root: root, store: store} do
      blob = Blob.new("important\n")
      {:ok, sha, _store} = ObjectStore.put(store, blob)

      <<a::binary-size(2), _rest::binary>> = Base.encode16(sha, case: :lower)
      dir = Path.join([root, "objects", a])

      stray =
        dir
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, ".tmp."))

      assert stray == [], "stray tmp files left behind: #{inspect(stray)}"
    end

    test "second put of the same content is idempotent", %{store: store} do
      blob = Blob.new("dup\n")
      {:ok, sha1, _} = ObjectStore.put(store, blob)
      {:ok, sha2, _} = ObjectStore.put(store, blob)
      assert sha1 == sha2
    end
  end
end
