defmodule Exgit.IndexTest do
  use ExUnit.Case, async: true

  alias Exgit.Index

  setup do
    base = Path.join(System.tmp_dir!(), "exgit_index_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  describe "parse/1" do
    test "parses a v2 index with one entry" do
      index_bin =
        build_index(2, [entry("hello.txt", sha_bytes("ab" <> String.duplicate("0", 38)))])

      assert {:ok, %Index{version: 2, entries: [entry]}} = Index.parse(index_bin)
      assert entry.name == "hello.txt"
      assert entry.mode == 0o100644
      assert entry.stage == 0
    end

    test "parses multiple entries in sorted order" do
      entries = [
        entry("a.txt", sha_bytes("aa" <> String.duplicate("0", 38))),
        entry("b.txt", sha_bytes("bb" <> String.duplicate("0", 38))),
        entry("c/d.txt", sha_bytes("cc" <> String.duplicate("0", 38)))
      ]

      index_bin = build_index(2, entries)
      assert {:ok, %Index{entries: parsed}} = Index.parse(index_bin)
      assert length(parsed) == 3
      assert Enum.map(parsed, & &1.name) == ["a.txt", "b.txt", "c/d.txt"]
    end

    test "rejects invalid signature" do
      assert {:error, :invalid_index} = Index.parse(<<"BAAD", 2::32, 0::32>>)
    end

    test "rejects unsupported version" do
      assert {:error, {:unsupported_version, 99}} = Index.parse(<<"DIRC", 99::32, 0::32>>)
    end
  end

  describe "read/1" do
    @tag :git_cross_check
    test "reads an index created by git", %{base: base} do
      repo = Path.join(base, "repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
      file = Path.join(repo, "test.txt")
      File.write!(file, "content\n")
      {_, 0} = System.cmd("git", ["add", "test.txt"], cd: repo, stderr_to_stdout: true)

      index_path = Path.join([repo, ".git", "index"])
      assert {:ok, %Index{entries: [entry]}} = Index.read(index_path)
      assert entry.name == "test.txt"
      assert entry.mode == 0o100644

      expected_sha = :crypto.hash(:sha, "blob 8\0content\n")
      assert entry.sha == expected_sha
    end

    @tag :git_cross_check
    test "reads index with multiple files", %{base: base} do
      repo = Path.join(base, "repo2")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

      File.write!(Path.join(repo, "a.txt"), "aaa\n")
      File.mkdir_p!(Path.join(repo, "sub"))
      File.write!(Path.join([repo, "sub", "b.txt"]), "bbb\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)

      index_path = Path.join([repo, ".git", "index"])
      assert {:ok, %Index{entries: entries}} = Index.read(index_path)
      names = Enum.map(entries, & &1.name)
      assert "a.txt" in names
      assert "sub/b.txt" in names
    end
  end

  describe "entries/1" do
    test "returns the entry list" do
      index = %Index{entries: [%Index.Entry{name: "x", sha: <<0::160>>, mode: 0o100644}]}
      assert [%Index.Entry{name: "x"}] = Index.entries(index)
    end
  end

  # --- Helpers ---

  defp sha_bytes(hex), do: Base.decode16!(hex, case: :mixed)

  defp entry(name, sha, opts \\ []) do
    mode = Keyword.get(opts, :mode, 0o100644)
    {name, sha, mode}
  end

  defp build_index(version, entries) do
    entry_data =
      entries
      |> Enum.map(fn {name, sha, mode} ->
        name_bin = name
        name_len = min(byte_size(name_bin), 0xFFF)
        flags = name_len

        base = 62
        nul_count = 8 - rem(base + byte_size(name_bin), 8)

        <<0::32, 0::32, 0::32, 0::32, 0::32, 0::32, mode::32, 0::32, 0::32, 0::32,
          sha::binary-size(20), flags::16, name_bin::binary, 0::size(nul_count * 8)>>
      end)
      |> IO.iodata_to_binary()

    header = <<"DIRC", version::32, length(entries)::32>>
    body = header <> entry_data
    checksum = :crypto.hash(:sha, body)
    body <> checksum
  end
end
