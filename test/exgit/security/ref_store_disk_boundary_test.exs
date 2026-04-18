defmodule Exgit.Security.RefStoreDiskBoundaryTest do
  @moduledoc """
  Regression for review finding #1.

  Defense-in-depth: every public entry point on `RefStore.Disk`
  re-validates its ref-name argument, even though `Exgit.clone/2`'s
  perimeter filter already rejects hostile names. This protects
  direct callers (bypass the perimeter) and the `resolve_ref/2`
  follow-symref path (where the target comes from a file on disk,
  not the wire).
  """

  use ExUnit.Case, async: true

  alias Exgit.RefStore.Disk

  @exploits [
    "../../etc/passwd",
    "refs/heads/../../../tmp/pwned",
    "/absolute/path",
    "refs/heads/foo\0bar",
    "refs/heads/foo bar",
    "refs/heads/..",
    "refs/heads/.hidden"
  ]

  setup do
    root =
      Path.join(System.tmp_dir!(), "exgit_ref_boundary_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "refs/heads"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: Disk.new(root)}
  end

  describe "read_ref/2 rejects hostile ref names" do
    test "returns :invalid_ref_name for each exploit", %{store: store} do
      for exploit <- @exploits do
        assert {:error, :invalid_ref_name} = Disk.read_ref(store, exploit),
               "expected :invalid_ref_name for #{inspect(exploit)}"
      end
    end
  end

  describe "write_ref/4 rejects hostile ref names" do
    test "returns :invalid_ref_name for each exploit", %{store: store} do
      sha = :binary.copy(<<1>>, 20)

      for exploit <- @exploits do
        assert {:error, :invalid_ref_name} = Disk.write_ref(store, exploit, sha),
               "expected :invalid_ref_name for #{inspect(exploit)}"
      end
    end

    test "rejects symbolic target escape", %{store: store} do
      # Even if the ref NAME is valid, a symbolic VALUE pointing at
      # `../../etc/passwd` must not be accepted.
      target = {:symbolic, "../../etc/passwd"}
      assert {:error, :invalid_ref_name} = Disk.write_ref(store, "HEAD", target)
    end
  end

  describe "resolve_ref/2 refuses to follow a hostile symref target on disk" do
    test "an on-disk ref file whose content is `ref: ../../etc/passwd` is refused",
         %{root: root, store: store} do
      # Manually write a malicious symbolic ref file — the public
      # write_ref API would refuse this, but a compromised FS or a
      # human-edited ref is possible.
      File.write!(Path.join(root, "HEAD"), "ref: ../../etc/passwd\n")

      assert {:error, :invalid_ref_name} = Disk.resolve_ref(store, "HEAD")
    end
  end

  describe "delete_ref/2 rejects hostile ref names" do
    test "returns :invalid_ref_name for each exploit", %{store: store} do
      for exploit <- @exploits do
        assert {:error, :invalid_ref_name} = Disk.delete_ref(store, exploit)
      end
    end
  end
end
