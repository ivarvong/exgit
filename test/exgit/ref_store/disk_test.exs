defmodule Exgit.RefStore.DiskTest do
  use ExUnit.Case, async: true

  alias Exgit.RefStore.Disk

  @sha :crypto.hash(:sha, "test")
  @sha2 :crypto.hash(:sha, "test2")

  setup do
    path =
      Path.join(System.tmp_dir!(), "exgit_refstore_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(path, "refs/heads"))
    File.mkdir_p!(Path.join(path, "refs/tags"))
    on_exit(fn -> File.rm_rf!(path) end)
    %{store: Disk.new(path), path: path}
  end

  test "write and read a ref", %{store: store} do
    assert :ok = Disk.write_ref(store, "refs/heads/main", @sha)
    assert {:ok, @sha} = Disk.read_ref(store, "refs/heads/main")
  end

  test "read HEAD as symbolic ref", %{store: store, path: path} do
    File.write!(Path.join(path, "HEAD"), "ref: refs/heads/main\n")
    assert {:ok, {:symbolic, "refs/heads/main"}} = Disk.read_ref(store, "HEAD")
  end

  test "resolve follows symbolic refs", %{store: store, path: path} do
    File.write!(Path.join(path, "HEAD"), "ref: refs/heads/main\n")
    :ok = Disk.write_ref(store, "refs/heads/main", @sha)
    assert {:ok, @sha} = Disk.resolve_ref(store, "HEAD")
  end

  test "compare-and-swap", %{store: store} do
    :ok = Disk.write_ref(store, "refs/heads/main", @sha)

    assert {:error, :compare_and_swap_failed} =
             Disk.write_ref(store, "refs/heads/main", @sha2, expected: @sha2)

    assert :ok = Disk.write_ref(store, "refs/heads/main", @sha2, expected: @sha)
    assert {:ok, @sha2} = Disk.read_ref(store, "refs/heads/main")
  end

  test "delete", %{store: store} do
    :ok = Disk.write_ref(store, "refs/heads/main", @sha)
    assert :ok = Disk.delete_ref(store, "refs/heads/main")
    assert {:error, :not_found} = Disk.read_ref(store, "refs/heads/main")
  end

  test "list loose refs", %{store: store} do
    :ok = Disk.write_ref(store, "refs/heads/main", @sha)
    :ok = Disk.write_ref(store, "refs/heads/dev", @sha2)
    :ok = Disk.write_ref(store, "refs/tags/v1", @sha)

    heads = Disk.list_refs(store, "refs/heads/")
    assert length(heads) == 2
    assert {"refs/heads/dev", @sha2} in heads
    assert {"refs/heads/main", @sha} in heads
  end

  test "reads packed-refs", %{store: store, path: path} do
    packed =
      "# pack-refs with: peeled fully-peeled sorted\n#{Base.encode16(@sha, case: :lower)} refs/heads/packed\n"

    File.write!(Path.join(path, "packed-refs"), packed)

    assert {:ok, @sha} = Disk.read_ref(store, "refs/heads/packed")
  end

  test "loose refs override packed-refs", %{store: store, path: path} do
    packed = "#{Base.encode16(@sha, case: :lower)} refs/heads/main\n"
    File.write!(Path.join(path, "packed-refs"), packed)
    :ok = Disk.write_ref(store, "refs/heads/main", @sha2)

    assert {:ok, @sha2} = Disk.read_ref(store, "refs/heads/main")

    refs = Disk.list_refs(store, "refs/heads/")
    main_refs = Enum.filter(refs, fn {r, _} -> r == "refs/heads/main" end)
    assert length(main_refs) == 1
    assert {_, @sha2} = hd(main_refs)
  end
end
