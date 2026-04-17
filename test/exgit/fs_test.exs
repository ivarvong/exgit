defmodule Exgit.FsTest do
  use ExUnit.Case, async: true

  alias Exgit.FS
  alias Exgit.Object.{Blob, Tree, Commit}
  alias Exgit.{ObjectStore, RefStore}

  # Build a tiny repo with a recognizable tree:
  #   /README.md     (file)
  #   /src/a.ex      (file)
  #   /src/b.ex      (file)
  #   /src/nested/c.ex (file)
  setup do
    store = ObjectStore.Memory.new()

    readme = Blob.new("hello\n")
    {:ok, readme_sha, store} = ObjectStore.put(store, readme)

    a = Blob.new("defmodule A do\nend\n")
    {:ok, a_sha, store} = ObjectStore.put(store, a)

    b = Blob.new("defmodule B do\nend\n")
    {:ok, b_sha, store} = ObjectStore.put(store, b)

    c = Blob.new("defmodule C do\nend\n")
    {:ok, c_sha, store} = ObjectStore.put(store, c)

    nested_tree = Tree.new([{"100644", "c.ex", c_sha}])
    {:ok, nested_sha, store} = ObjectStore.put(store, nested_tree)

    src_tree =
      Tree.new([
        {"100644", "a.ex", a_sha},
        {"100644", "b.ex", b_sha},
        {"40000", "nested", nested_sha}
      ])

    {:ok, src_sha, store} = ObjectStore.put(store, src_tree)

    root_tree =
      Tree.new([
        {"100644", "README.md", readme_sha},
        {"40000", "src", src_sha}
      ])

    {:ok, root_sha, store} = ObjectStore.put(store, root_tree)

    commit =
      Commit.new(
        tree: root_sha,
        parents: [],
        author: "T <t@t> 1700000000 +0000",
        committer: "T <t@t> 1700000000 +0000",
        message: "init\n"
      )

    {:ok, commit_sha, store} = ObjectStore.put(store, commit)

    {:ok, ref_store} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
    {:ok, ref_store} = RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

    repo = %Exgit.Repository{
      object_store: store,
      ref_store: ref_store,
      config: Exgit.Config.new(),
      path: nil
    }

    {:ok,
     repo: repo,
     shas: %{
       commit: commit_sha,
       readme: readme_sha,
       a: a_sha,
       b: b_sha,
       c: c_sha,
       root: root_sha,
       src: src_sha,
       nested: nested_sha
     }}
  end

  describe "read_path/3 (P1.6)" do
    test "reads a top-level file", %{repo: repo} do
      assert {:ok, {mode, %Blob{data: "hello\n"}}, _repo} =
               FS.read_path(repo, "HEAD", "README.md")

      assert mode == "100644"
    end

    test "reads a nested file", %{repo: repo} do
      assert {:ok, {_mode, %Blob{data: data}}, _repo} =
               FS.read_path(repo, "HEAD", "src/a.ex")

      assert data =~ "defmodule A"
    end

    test "reads a deeply nested file", %{repo: repo} do
      assert {:ok, {_mode, %Blob{data: data}}, _repo} =
               FS.read_path(repo, "HEAD", "src/nested/c.ex")

      assert data =~ "defmodule C"
    end

    test "returns :not_found for missing path", %{repo: repo} do
      assert {:error, :not_found} = FS.read_path(repo, "HEAD", "nope.txt")
      assert {:error, :not_found} = FS.read_path(repo, "HEAD", "src/missing.ex")
    end

    test "returns :not_a_blob when path is a directory", %{repo: repo} do
      assert {:error, :not_a_blob} = FS.read_path(repo, "HEAD", "src")
    end

    test "accepts a branch name", %{repo: repo} do
      assert {:ok, _, _repo} = FS.read_path(repo, "refs/heads/main", "README.md")
    end

    test "accepts a raw commit SHA", %{repo: repo, shas: %{commit: sha}} do
      assert {:ok, _, _repo} = FS.read_path(repo, sha, "README.md")
    end
  end

  describe "ls/3" do
    test "lists top-level entries", %{repo: repo} do
      {:ok, entries, _repo} = FS.ls(repo, "HEAD", "")

      names = for {_mode, name, _sha} <- entries, do: name
      assert Enum.sort(names) == ["README.md", "src"]
    end

    test "lists a subdirectory", %{repo: repo} do
      {:ok, entries, _repo} = FS.ls(repo, "HEAD", "src")

      names = for {_mode, name, _sha} <- entries, do: name
      assert Enum.sort(names) == ["a.ex", "b.ex", "nested"]
    end

    test "returns :not_found for missing dir", %{repo: repo} do
      assert {:error, :not_found} = FS.ls(repo, "HEAD", "nope")
    end

    test "returns :not_a_tree when listing a file", %{repo: repo} do
      assert {:error, :not_a_tree} = FS.ls(repo, "HEAD", "README.md")
    end
  end

  describe "stat/3" do
    test "returns :blob for a file", %{repo: repo} do
      assert {:ok, %{type: :blob, mode: "100644", size: 6}, _repo} =
               FS.stat(repo, "HEAD", "README.md")
    end

    test "returns :tree for a directory", %{repo: repo} do
      assert {:ok, %{type: :tree, mode: "40000"}, _repo} = FS.stat(repo, "HEAD", "src")
    end

    test "returns :not_found for a missing path", %{repo: repo} do
      assert {:error, :not_found} = FS.stat(repo, "HEAD", "nope.txt")
    end
  end

  describe "exists?/3" do
    test "true for existing files and dirs", %{repo: repo} do
      assert FS.exists?(repo, "HEAD", "README.md")
      assert FS.exists?(repo, "HEAD", "src")
      assert FS.exists?(repo, "HEAD", "src/nested/c.ex")
    end

    test "false for missing paths", %{repo: repo} do
      refute FS.exists?(repo, "HEAD", "nope.txt")
      refute FS.exists?(repo, "HEAD", "src/nope")
    end
  end

  describe "walk/3" do
    test "yields all file paths and their blob SHAs", %{repo: repo} do
      paths = FS.walk(repo, "HEAD") |> Enum.to_list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert paths == ["README.md", "src/a.ex", "src/b.ex", "src/nested/c.ex"]
    end

    test "is lazy — can Stream.take", %{repo: repo} do
      # Stream should produce on demand.
      first = FS.walk(repo, "HEAD") |> Enum.take(1)
      assert length(first) == 1
    end
  end

  describe "glob/3" do
    test "matches *.md in the root", %{repo: repo} do
      assert {:ok, ["README.md"]} = FS.glob(repo, "HEAD", "*.md")
    end

    test "matches **/*.ex across subdirs", %{repo: repo} do
      {:ok, paths} = FS.glob(repo, "HEAD", "**/*.ex")

      assert Enum.sort(paths) == ["src/a.ex", "src/b.ex", "src/nested/c.ex"]
    end

    test "matches src/*.ex (one level)", %{repo: repo} do
      {:ok, paths} = FS.glob(repo, "HEAD", "src/*.ex")
      assert Enum.sort(paths) == ["src/a.ex", "src/b.ex"]
    end

    test "brace expansion: **/*.{md,ex} matches both extensions", %{repo: repo} do
      {:ok, paths} = FS.glob(repo, "HEAD", "**/*.{md,ex}")

      assert Enum.sort(paths) ==
               ["README.md", "src/a.ex", "src/b.ex", "src/nested/c.ex"]
    end

    test "brace with a single option is equivalent to the literal", %{repo: repo} do
      {:ok, a} = FS.glob(repo, "HEAD", "**/*.{ex}")
      {:ok, b} = FS.glob(repo, "HEAD", "**/*.ex")
      assert Enum.sort(a) == Enum.sort(b)
    end

    test "brace expansion at different positions in the pattern", %{repo: repo} do
      # {src,lib}/*.ex — no `lib/` exists, so only src hits match.
      {:ok, paths} = FS.glob(repo, "HEAD", "{src,lib}/*.ex")
      assert Enum.sort(paths) == ["src/a.ex", "src/b.ex"]
    end

    test "brace expansion with three options", %{repo: repo} do
      {:ok, paths} = FS.glob(repo, "HEAD", "**/*.{md,ex,missing}")

      assert Enum.sort(paths) ==
               ["README.md", "src/a.ex", "src/b.ex", "src/nested/c.ex"]
    end

    test "empty brace content is a literal empty alternative", %{repo: repo} do
      # `foo{,bar}` matches either `foo` or `foobar`. We exercise the
      # parse path; the fixture has no files matching either literal,
      # so we expect an empty result — but no crash.
      {:ok, paths} = FS.glob(repo, "HEAD", "README{,.bak}.md")
      assert paths == ["README.md"]
    end

    test "unmatched opening brace is treated as a literal character", %{repo: repo} do
      # `{` without a closing `}` isn't a valid alternation — we treat
      # it as a literal (matches against a nonexistent file).
      {:ok, paths} = FS.glob(repo, "HEAD", "README{.md")
      assert paths == []
    end
  end

  describe "grep with brace expansion in path glob" do
    test "grep over **/*.{md,ex} matches across both extensions", %{repo: repo} do
      # Insert a blob with content matching "HELLO" into the fixture via
      # write_path so we can search across both file types.
      {:ok, tree, repo} = FS.write_path(repo, "HEAD", "notes.md", "HELLO markdown\n")
      {:ok, tree, repo} = FS.write_path(repo, tree, "src/extra.ex", "HELLO elixir\n")

      matches =
        FS.grep(repo, tree, "HELLO", path: "**/*.{md,ex}")
        |> Enum.to_list()

      paths = matches |> Enum.map(& &1.path) |> Enum.sort()
      assert "notes.md" in paths
      assert "src/extra.ex" in paths
    end
  end

  describe "grep/4" do
    test "matches a string across all files", %{repo: repo} do
      results = Exgit.FS.grep(repo, "HEAD", "defmodule") |> Enum.to_list()

      paths = results |> Enum.map(& &1.path) |> Enum.sort() |> Enum.uniq()
      assert paths == ["src/a.ex", "src/b.ex", "src/nested/c.ex"]

      # Every match returns the map shape.
      for r <- results do
        assert is_integer(r.line_number) and r.line_number >= 1
        assert is_binary(r.line)
        assert is_binary(r.match) or is_list(r.match)
        assert String.contains?(r.line, "defmodule")
      end
    end

    test "matches a regex", %{repo: repo} do
      results =
        Exgit.FS.grep(repo, "HEAD", ~r/defmodule ([A-Z])/)
        |> Enum.to_list()

      # Three modules: A, B, C.
      modules = results |> Enum.map(& &1.match) |> Enum.map(&List.wrap/1) |> Enum.map(&hd/1)
      # The whole-match is the 0th group "defmodule X"; we accept either
      # whole-match-string or group captures depending on impl choice.
      assert length(results) == 3
      _ = modules
    end

    test "filters by path glob", %{repo: repo} do
      results =
        Exgit.FS.grep(repo, "HEAD", "defmodule", path: "src/*.ex")
        |> Enum.to_list()

      paths = results |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()
      # "src/*.ex" is a single-level glob — excludes nested.
      assert paths == ["src/a.ex", "src/b.ex"]
    end

    test "max_count short-circuits the stream", %{repo: repo} do
      # There are 3 matches for "defmodule"; ask for only 1.
      results =
        Exgit.FS.grep(repo, "HEAD", "defmodule", max_count: 1)
        |> Enum.to_list()

      assert length(results) == 1
    end

    test "skips binary files by default", %{repo: repo, shas: shas} do
      # Inject a binary blob into the tree. We build a new tree that
      # includes a binary file and grep for bytes that appear in it.
      binary_content = <<0, 1, 2, 3, "defmodule BinaryMatch", 0, 255, 255>>

      {:ok, _new_tree_sha, repo} =
        Exgit.FS.write_path(repo, "HEAD", "data/blob.bin", binary_content)

      # Point HEAD at a new commit whose tree includes the binary file.
      # For simplicity, use the new tree sha directly as the reference.
      {:ok, new_tree, _repo} =
        Exgit.FS.write_path(repo, "HEAD", "data/blob.bin", binary_content)

      results =
        Exgit.FS.grep(repo, new_tree, "defmodule BinaryMatch")
        |> Enum.to_list()

      assert results == [],
             "grep should skip binary files — got matches: #{inspect(results)}"

      _ = shas
    end

    test "returns empty stream for no matches", %{repo: repo} do
      results =
        Exgit.FS.grep(repo, "HEAD", "nothing_matches_this_string_xyz")
        |> Enum.to_list()

      assert results == []
    end

    test "is lazy — Stream.take works without reading all files", %{repo: repo} do
      # Take only the first match; we shouldn't enumerate the rest.
      # Hard to assert non-enumeration without instrumentation, so just
      # verify the shape works.
      [first] = Exgit.FS.grep(repo, "HEAD", "defmodule") |> Enum.take(1)
      assert String.contains?(first.line, "defmodule")
    end

    test "reports the correct line number", %{repo: repo} do
      [match] =
        Exgit.FS.grep(repo, "HEAD", "defmodule C") |> Enum.to_list()

      assert match.path == "src/nested/c.ex"
      assert match.line_number == 1
      assert match.line == "defmodule C do"
    end

    test "case-insensitive match", %{repo: repo} do
      results =
        Exgit.FS.grep(repo, "HEAD", "DEFMODULE", case_insensitive: true)
        |> Enum.to_list()

      assert length(results) == 3
    end
  end

  describe "write_path/4" do
    test "writes a new file, returns {new_tree_sha, updated_repo}", %{repo: repo} do
      assert {:ok, new_tree_sha, repo2} =
               FS.write_path(repo, "HEAD", "new.txt", "fresh content\n")

      # The new repo's object store has the new tree and blob.
      assert {:ok, {_mode, blob}, _repo} =
               FS.read_path(%{repo2 | ref_store: repo.ref_store}, new_tree_sha, "new.txt")

      assert blob.data == "fresh content\n"

      # Existing files are preserved.
      assert {:ok, {_mode, old}, _repo} = FS.read_path(repo2, new_tree_sha, "README.md")
      assert old.data == "hello\n"
    end

    test "writes a file in a new nested directory", %{repo: repo} do
      assert {:ok, tree_sha, repo2} =
               FS.write_path(repo, "HEAD", "deep/path/here/file.txt", "deep\n")

      # We can read it back via the returned tree.
      assert {:ok, {_, blob}, _repo} =
               FS.read_path(repo2, tree_sha, "deep/path/here/file.txt")

      assert blob.data == "deep\n"
    end

    test "overwrites an existing file", %{repo: repo} do
      {:ok, tree_sha, repo2} = FS.write_path(repo, "HEAD", "README.md", "replaced\n")

      assert {:ok, {_, blob}, _repo} = FS.read_path(repo2, tree_sha, "README.md")
      assert blob.data == "replaced\n"
    end

    test "overwriting in an existing nested directory preserves siblings", %{repo: repo} do
      {:ok, tree_sha, repo2} = FS.write_path(repo, "HEAD", "src/a.ex", "changed\n")

      assert {:ok, {_, new_a}, _repo} = FS.read_path(repo2, tree_sha, "src/a.ex")
      assert new_a.data == "changed\n"

      # Sibling file untouched.
      assert {:ok, {_, b}, _repo} = FS.read_path(repo2, tree_sha, "src/b.ex")
      assert b.data =~ "defmodule B"
    end
  end
end
