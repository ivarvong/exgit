defmodule Exgit.Security.TreeEntryNameTest do
  @moduledoc """
  Regression for review finding #2.

  A hostile remote can ship a tree object whose entry names contain
  `..`, `/`, embedded NULs, or reserved names like `.git` /
  `.gitmodules`. Previously `Tree.decode/1` accepted any bytes
  between the mode-space and the NUL terminator as a valid entry
  name, which would flow unchecked into `FS.read_path`, a future
  checkout, and `insert_blob_into_tree` (laundering hostile trees
  back to the store).

  The fix validates every entry name at decode time, rejecting:

    * empty names
    * `.` and `..`
    * names containing `/` or NUL
    * case-insensitive `.git` / `.gitmodules`
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Tree

  # Build a raw tree entry: `<mode> <name>\0<20-byte sha>`.
  defp entry(mode, name, sha) do
    [mode, ?\s, name, 0, sha]
    |> IO.iodata_to_binary()
  end

  @sha :binary.copy(<<0xAB>>, 20)

  describe "decode/1 rejects path-traversal names" do
    test "empty name" do
      raw = entry("100644", "", @sha)
      assert {:error, {:tree_entry_name_empty, _}} = safe_decode(raw)
    end

    test "bare `.`" do
      raw = entry("100644", ".", @sha)
      assert {:error, {:tree_entry_name_dot, _}} = safe_decode(raw)
    end

    test "bare `..`" do
      raw = entry("100644", "..", @sha)
      assert {:error, {:tree_entry_name_dotdot, _}} = safe_decode(raw)
    end

    test "name containing `/`" do
      raw = entry("100644", "foo/bar", @sha)
      assert {:error, {:tree_entry_name_contains_slash, "foo/bar"}} = safe_decode(raw)
    end

    test "leading `/`" do
      raw = entry("100644", "/absolute", @sha)
      assert {:error, {:tree_entry_name_contains_slash, _}} = safe_decode(raw)
    end

    test "`.git` is reserved (case-insensitive)" do
      for variant <- [".git", ".GIT", ".Git"] do
        raw = entry("40000", variant, @sha)
        assert {:error, {:tree_entry_name_reserved, ^variant}} = safe_decode(raw)
      end
    end

    test "`.gitmodules` is reserved (case-insensitive)" do
      for variant <- [".gitmodules", ".GITMODULES", ".GitModules"] do
        raw = entry("100644", variant, @sha)
        assert {:error, {:tree_entry_name_reserved, ^variant}} = safe_decode(raw)
      end
    end

    test "legitimate names are accepted" do
      raw = entry("100644", "README.md", @sha)
      assert {:ok, %Tree{entries: [{"100644", "README.md", @sha}]}} = Tree.decode(raw)
    end

    test "nested directory entry (mode 40000) with valid name" do
      raw = entry("40000", "src", @sha)
      assert {:ok, %Tree{entries: [{"40000", "src", @sha}]}} = Tree.decode(raw)
    end
  end

  # Wrap the return in a {:error, {code, name}} shape for uniform
  # assertions — Tree.decode returns {:error, {code, name}} directly
  # from validate_entry_name/1 for all but the empty/./.. cases, which
  # return {:error, atom}. Normalize here.
  defp safe_decode(raw) do
    case Tree.decode(raw) do
      {:ok, _} = ok -> ok
      {:error, atom} when is_atom(atom) -> {:error, {atom, nil}}
      {:error, {_code, _name}} = err -> err
    end
  end
end
