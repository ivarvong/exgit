defmodule Exgit.FsTest do
  use ExUnit.Case, async: true

  alias Exgit.{FS, ObjectStore, RefStore}
  alias Exgit.Object.{Blob, Commit, Tree}

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

  describe "read_path/4 with resolve_lfs_pointers" do
    # Build a repo containing:
    #   /real.bin       (200 bytes random — looks like a real binary)
    #   /pointed.bin    (a valid LFS pointer file, as if `git lfs`
    #                   replaced the real content on commit)
    #   /README.md      (plain text)
    #
    # and verify:
    #   1. Default behavior (no flag) returns %Blob{} in all cases.
    #   2. With resolve_lfs_pointers: true, pointed.bin surfaces as
    #      {:lfs_pointer, info}; real.bin and README.md stay as blobs.
    setup do
      store = ObjectStore.Memory.new()

      readme = Blob.new("# Project\n")
      {:ok, readme_sha, store} = ObjectStore.put(store, readme)

      # A real binary blob — 200 random bytes that should NEVER be
      # mistaken for a pointer.
      real_bin = Blob.new(:crypto.strong_rand_bytes(200))
      {:ok, real_bin_sha, store} = ObjectStore.put(store, real_bin)

      # A canonical LFS pointer (exactly what `git-lfs` would have
      # written in place of a real binary). Size + oid are for a
      # hypothetical 12345-byte payload.
      pointer_text = """
      version https://git-lfs.github.com/spec/v1
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      size 12345
      """

      pointer_blob = Blob.new(pointer_text)
      {:ok, pointer_sha, store} = ObjectStore.put(store, pointer_blob)

      root =
        Tree.new([
          {"100644", "README.md", readme_sha},
          {"100644", "pointed.bin", pointer_sha},
          {"100644", "real.bin", real_bin_sha}
        ])

      {:ok, root_sha, store} = ObjectStore.put(store, root)

      commit =
        Commit.new(
          tree: root_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "init\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      {:ok, ref_store} =
        RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])

      {:ok, ref_store} =
        RefStore.write(ref_store, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Exgit.Repository{
        object_store: store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      {:ok, repo: repo, pointer_text: pointer_text}
    end

    test "default behavior returns raw blob even for pointer files", %{
      repo: repo,
      pointer_text: pointer_text
    } do
      # Without the flag, an agent reading pointed.bin sees the ~130
      # bytes of pointer text as if it were the actual file. This is
      # the silent-correctness-cliff the flag exists to close.
      assert {:ok, {"100644", %Blob{data: ^pointer_text}}, _} =
               FS.read_path(repo, "HEAD", "pointed.bin")
    end

    test "with flag, pointer file surfaces as {:lfs_pointer, info}", %{repo: repo} do
      assert {:ok, {"100644", {:lfs_pointer, info}}, _} =
               FS.read_path(repo, "HEAD", "pointed.bin", resolve_lfs_pointers: true)

      assert info.oid ==
               "sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"

      assert info.size == 12_345
      assert is_binary(info.raw)
    end

    test "with flag, normal binary blob stays as %Blob{}", %{repo: repo} do
      # A 200-byte random blob must NOT be mistaken for a pointer.
      assert {:ok, {"100644", %Blob{} = blob}, _} =
               FS.read_path(repo, "HEAD", "real.bin", resolve_lfs_pointers: true)

      assert byte_size(blob.data) == 200
    end

    test "with flag, plain text blob stays as %Blob{}", %{repo: repo} do
      assert {:ok, {"100644", %Blob{data: "# Project\n"}}, _} =
               FS.read_path(repo, "HEAD", "README.md", resolve_lfs_pointers: true)
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

  describe "multi_grep/4" do
    setup do
      store = ObjectStore.Memory.new()

      auth_ex = """
      defmodule Auth do
        @auth_token System.get_env("AUTH_TOKEN")
        @api_key System.get_env("API_KEY")

        def check, do: :ok
      end
      """

      logging_ex = """
      defmodule Logging do
        # no secrets here
        def info(msg), do: IO.puts(msg)
      end
      """

      mixed_ex = """
      # auth_token AND api_key both appear here
      defmodule Mixed do
        @creds {@auth_token, @api_key}
      end
      """

      {:ok, a_sha, store} = ObjectStore.put(store, Blob.new(auth_ex))
      {:ok, l_sha, store} = ObjectStore.put(store, Blob.new(logging_ex))
      {:ok, m_sha, store} = ObjectStore.put(store, Blob.new(mixed_ex))

      tree =
        Tree.new([
          {"100644", "auth.ex", a_sha},
          {"100644", "logging.ex", l_sha},
          {"100644", "mixed.ex", m_sha}
        ])

      {:ok, tree_sha, store} = ObjectStore.put(store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "mg\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
      {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Exgit.Repository{
        object_store: store,
        ref_store: rs,
        config: Exgit.Config.new(),
        path: nil
      }

      {:ok, repo: repo}
    end

    test "map-form tagging with atoms", %{repo: repo} do
      patterns = %{token: "auth_token", key: "api_key"}

      results = FS.multi_grep(repo, "HEAD", patterns) |> Enum.to_list()

      # auth.ex has token at line 2, key at line 3.
      # mixed.ex has token at line 1 + line 3, key at line 1 + line 3.
      by_tag = Enum.group_by(results, & &1.tag)

      assert Map.keys(by_tag) |> Enum.sort() == [:key, :token]

      # Every result carries a tag.
      for r <- results do
        assert r.tag in [:token, :key]
        assert is_integer(r.line_number) and r.line_number >= 1
      end
    end

    test "list-form uses pattern as its own tag", %{repo: repo} do
      patterns = ["auth_token", "api_key"]

      results = FS.multi_grep(repo, "HEAD", patterns) |> Enum.to_list()

      tags = results |> Enum.map(& &1.tag) |> Enum.uniq() |> Enum.sort()
      assert tags == ["api_key", "auth_token"]
    end

    test "empty pattern map returns empty stream", %{repo: repo} do
      results = FS.multi_grep(repo, "HEAD", %{}) |> Enum.to_list()
      assert results == []
    end

    test "same line matched by two patterns produces two rows", %{repo: repo} do
      # mixed.ex line 3 contains both @auth_token and @api_key.
      patterns = %{token: "auth_token", key: "api_key"}

      rows =
        FS.multi_grep(repo, "HEAD", patterns, path: "mixed.ex")
        |> Enum.to_list()
        |> Enum.filter(&(&1.line_number == 3))

      tags = rows |> Enum.map(& &1.tag) |> Enum.sort()
      assert tags == [:key, :token]
    end

    test "context applies to every pattern", %{repo: repo} do
      patterns = %{token: "auth_token"}

      [match] =
        FS.multi_grep(repo, "HEAD", patterns, path: "auth.ex", context: 1)
        |> Enum.to_list()

      assert match.tag == :token
      assert match.line_number == 2
      assert match.context_before == [{1, "defmodule Auth do"}]
    end

    test "case_insensitive applies uniformly", %{repo: repo} do
      patterns = %{token: "AUTH_TOKEN", key: "API_KEY"}

      # auth.ex has @auth_token / @api_key (lowercase).
      results =
        FS.multi_grep(repo, "HEAD", patterns, path: "auth.ex", case_insensitive: true)
        |> Enum.to_list()

      tags = results |> Enum.map(& &1.tag) |> Enum.uniq() |> Enum.sort()
      assert tags == [:key, :token]
    end

    test "path glob filters as in grep/4", %{repo: repo} do
      patterns = %{token: "auth_token"}

      results =
        FS.multi_grep(repo, "HEAD", patterns, path: "logging.ex") |> Enum.to_list()

      # logging.ex has no tokens — empty.
      assert results == []
    end

    test "max_count caps across all patterns", %{repo: repo} do
      patterns = %{token: "auth_token", key: "api_key"}

      results = FS.multi_grep(repo, "HEAD", patterns, max_count: 2) |> Enum.to_list()
      assert length(results) == 2
    end

    test "tag can be any term (tuple, string)", %{repo: repo} do
      patterns = %{{:sev, :high} => "auth_token", "ascii-tag" => "api_key"}

      results = FS.multi_grep(repo, "HEAD", patterns) |> Enum.to_list()

      tags = results |> Enum.map(& &1.tag) |> Enum.uniq() |> Enum.sort()
      assert tags == [{:sev, :high}, "ascii-tag"]
    end

    test "regex patterns work same as strings", %{repo: repo} do
      patterns = %{token: ~r/auth_\w+/}

      results = FS.multi_grep(repo, "HEAD", patterns) |> Enum.to_list()

      for r <- results do
        assert r.tag == :token
        assert Regex.match?(~r/auth_\w+/, r.match)
      end
    end

    test "grep/4 single-pattern behavior unchanged by multi_grep refactor",
         %{repo: repo} do
      # Sanity: grep still returns no :tag field.
      [first | _] = FS.grep(repo, "HEAD", "auth_token") |> Enum.to_list()
      refute Map.has_key?(first, :tag)
    end
  end

  describe "read_lines/4" do
    setup do
      store = ObjectStore.Memory.new()

      # 10-line file.
      decad = Enum.map_join(1..10, "\n", &"line #{&1}") <> "\n"
      # File without trailing newline.
      no_trail = "a\nb\nc"
      # Empty file.
      empty = ""

      {:ok, d_sha, store} = ObjectStore.put(store, Blob.new(decad))
      {:ok, n_sha, store} = ObjectStore.put(store, Blob.new(no_trail))
      {:ok, e_sha, store} = ObjectStore.put(store, Blob.new(empty))

      tree =
        Tree.new([
          {"100644", "decad.txt", d_sha},
          {"100644", "empty.txt", e_sha},
          {"100644", "no_trail.txt", n_sha}
        ])

      {:ok, tree_sha, store} = ObjectStore.put(store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "init\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
      {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Exgit.Repository{
        object_store: store,
        ref_store: rs,
        config: Exgit.Config.new(),
        path: nil
      }

      {:ok, repo: repo}
    end

    test "single line integer", %{repo: repo} do
      assert {:ok, [{3, "line 3"}], _} = FS.read_lines(repo, "HEAD", "decad.txt", 3)
    end

    test "inclusive range", %{repo: repo} do
      assert {:ok, lines, _} = FS.read_lines(repo, "HEAD", "decad.txt", 3..5)
      assert lines == [{3, "line 3"}, {4, "line 4"}, {5, "line 5"}]
    end

    test "first line", %{repo: repo} do
      assert {:ok, [{1, "line 1"}], _} = FS.read_lines(repo, "HEAD", "decad.txt", 1)
    end

    test "last line of file ending with newline", %{repo: repo} do
      assert {:ok, [{10, "line 10"}], _} = FS.read_lines(repo, "HEAD", "decad.txt", 10)
    end

    test "last (partial) line of file not ending with newline", %{repo: repo} do
      assert {:ok, [{3, "c"}], _} = FS.read_lines(repo, "HEAD", "no_trail.txt", 3)
    end

    test "range overshooting EOF returns only existing lines", %{repo: repo} do
      assert {:ok, lines, _} = FS.read_lines(repo, "HEAD", "decad.txt", 8..100)
      assert lines == [{8, "line 8"}, {9, "line 9"}, {10, "line 10"}]
    end

    test "range entirely past EOF returns empty", %{repo: repo} do
      assert {:ok, [], _} = FS.read_lines(repo, "HEAD", "decad.txt", 100..200)
    end

    test "empty file returns empty list", %{repo: repo} do
      assert {:ok, [], _} = FS.read_lines(repo, "HEAD", "empty.txt", 1..10)
    end

    test "list of integers and ranges, deduplicated + sorted", %{repo: repo} do
      assert {:ok, lines, _} =
               FS.read_lines(repo, "HEAD", "decad.txt", [5, 1..2, 5, 8..9])

      assert lines == [
               {1, "line 1"},
               {2, "line 2"},
               {5, "line 5"},
               {8, "line 8"},
               {9, "line 9"}
             ]
    end

    test "rejects zero or negative line numbers", %{repo: repo} do
      assert {:error, {:invalid_line_range, 0}} =
               FS.read_lines(repo, "HEAD", "decad.txt", 0)

      assert {:error, {:invalid_line_range, -1}} =
               FS.read_lines(repo, "HEAD", "decad.txt", -1)
    end

    test "rejects non-unit step ranges", %{repo: repo} do
      assert {:error, {:invalid_line_range, _}} =
               FS.read_lines(repo, "HEAD", "decad.txt", 1..10//2)
    end

    test "empty explicit range is not an error, returns empty list", %{repo: repo} do
      assert {:ok, [], _} = FS.read_lines(repo, "HEAD", "decad.txt", 5..4)
    end

    test "missing path returns :not_found", %{repo: repo} do
      assert {:error, :not_found} =
               FS.read_lines(repo, "HEAD", "nope.txt", 1..5)
    end
  end

  describe "grep/4 with context" do
    # Dedicated fixture with rich, multi-line content so context
    # ranges actually have content to slice. Also exercises
    # start-of-file, end-of-file, and mid-file match positions.
    setup do
      store = ObjectStore.Memory.new()

      a_ex = """
      defmodule A do
        @moduledoc "first"
        def one, do: 1
        def two, do: 2
        def target, do: :hit
        def four, do: 4
        def five, do: 5
      end
      """

      b_ex = """
      defmodule B do
        def first, do: "first target"
        def middle, do: :ok
        def last, do: "last target"
      end
      """

      c_ex = "target\nonly one line after\n"

      {:ok, a_sha, store} = ObjectStore.put(store, Blob.new(a_ex))
      {:ok, b_sha, store} = ObjectStore.put(store, Blob.new(b_ex))
      {:ok, c_sha, store} = ObjectStore.put(store, Blob.new(c_ex))

      tree =
        Tree.new([
          {"100644", "a.ex", a_sha},
          {"100644", "b.ex", b_sha},
          {"100644", "c.ex", c_sha}
        ])

      {:ok, tree_sha, store} = ObjectStore.put(store, tree)

      commit =
        Commit.new(
          tree: tree_sha,
          parents: [],
          author: "T <t@t> 1700000000 +0000",
          committer: "T <t@t> 1700000000 +0000",
          message: "ctx fixture\n"
        )

      {:ok, commit_sha, store} = ObjectStore.put(store, commit)

      {:ok, rs} = RefStore.write(RefStore.Memory.new(), "refs/heads/main", commit_sha, [])
      {:ok, rs} = RefStore.write(rs, "HEAD", {:symbolic, "refs/heads/main"}, [])

      repo = %Exgit.Repository{
        object_store: store,
        ref_store: rs,
        config: Exgit.Config.new(),
        path: nil
      }

      {:ok, repo: repo}
    end

    test "no context option returns unchanged shape", %{repo: repo} do
      [match] = Exgit.FS.grep(repo, "HEAD", "target", path: "a.ex") |> Enum.to_list()
      refute Map.has_key?(match, :context_before)
      refute Map.has_key?(match, :context_after)
    end

    test ":context 2 yields 2 lines before + 2 after for a mid-file match", %{repo: repo} do
      [match] =
        Exgit.FS.grep(repo, "HEAD", "target", path: "a.ex", context: 2) |> Enum.to_list()

      assert match.line_number == 5

      assert match.context_before == [
               {3, "  def one, do: 1"},
               {4, "  def two, do: 2"}
             ]

      assert match.context_after == [
               {6, "  def four, do: 4"},
               {7, "  def five, do: 5"}
             ]
    end

    test ":before and :after can be set independently", %{repo: repo} do
      [match] =
        Exgit.FS.grep(repo, "HEAD", "target", path: "a.ex", before: 1, after: 3)
        |> Enum.to_list()

      assert match.context_before == [{4, "  def two, do: 2"}]

      assert match.context_after == [
               {6, "  def four, do: 4"},
               {7, "  def five, do: 5"},
               {8, "end"}
             ]
    end

    test "context clamps at start-of-file", %{repo: repo} do
      # In c.ex, "target" is on line 1 → no lines before.
      [match] =
        Exgit.FS.grep(repo, "HEAD", "target", path: "c.ex", context: 3) |> Enum.to_list()

      assert match.line_number == 1
      assert match.context_before == []
      assert match.context_after == [{2, "only one line after"}]
    end

    test "context clamps at end-of-file", %{repo: repo} do
      # Last line of b.ex (line 5) is "end"; "last target" is line 4.
      [match] =
        Exgit.FS.grep(repo, "HEAD", "last target", path: "b.ex", context: 5)
        |> Enum.to_list()

      assert match.line_number == 4
      # Only one line after ("end"), though we asked for 5.
      assert match.context_after == [{5, "end"}]
    end

    test "multiple matches in one file each get their own context", %{repo: repo} do
      # b.ex has "target" on lines 2 and 4.
      matches =
        Exgit.FS.grep(repo, "HEAD", "target", path: "b.ex", context: 1)
        |> Enum.to_list()

      assert length(matches) == 2

      [m2, m4] = Enum.sort_by(matches, & &1.line_number)

      assert m2.line_number == 2
      assert m2.context_before == [{1, "defmodule B do"}]
      assert m2.context_after == [{3, "  def middle, do: :ok"}]

      assert m4.line_number == 4
      assert m4.context_before == [{3, "  def middle, do: :ok"}]
      assert m4.context_after == [{5, "end"}]
    end

    test ":before alone adds only the before field", %{repo: repo} do
      [match] =
        Exgit.FS.grep(repo, "HEAD", "target", path: "a.ex", before: 2) |> Enum.to_list()

      assert match.context_before == [
               {3, "  def one, do: 1"},
               {4, "  def two, do: 2"}
             ]

      assert match.context_after == []
    end

    test "negative or zero values for :context don't add fields", %{repo: repo} do
      [match_zero] =
        Exgit.FS.grep(repo, "HEAD", "target", path: "a.ex", context: 0) |> Enum.to_list()

      refute Map.has_key?(match_zero, :context_before)

      [match_neg] =
        Exgit.FS.grep(repo, "HEAD", "target", path: "a.ex", context: -1) |> Enum.to_list()

      refute Map.has_key?(match_neg, :context_before)
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
