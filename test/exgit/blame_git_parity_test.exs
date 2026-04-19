defmodule Exgit.BlameGitParityTest do
  @moduledoc """
  Parity test: `Exgit.Blame.blame/3` attributes each line of a
  file to the same commit that `git blame --first-parent` would.

  Strategy:

    1. Generate a controlled linear history via real `git`
       (no merges, no renames — we only claim parity on
       first-parent-walkable history).
    2. Run `git blame --porcelain --first-parent` and parse
       the `(line_number, commit_sha)` mapping.
    3. Run `Exgit.Blame.blame` on the same repo.
    4. For each line, assert the commit_sha matches.

  Tagged `:real_git` + `:slow`.

  ### Limitations

  We do NOT test against real-world fixtures here because that
  opens the door to merge-commit and rename-commit semantics
  where exgit's 80% blame legitimately differs from git's full
  blame. A separate `:integration` test in
  `blame_real_fixture_test.exs` exercises the algorithm end-to-
  end on real repos, but asserts only that it produces an
  answer for every line (smoke + latency), not per-line parity.
  """

  use ExUnit.Case, async: false

  @moduletag :real_git
  @moduletag :slow

  alias Exgit.ObjectStore
  alias Exgit.Repository
  alias Exgit.Test.RealGit

  describe "per-line parity on controlled linear histories" do
    test "simple: append-only history" do
      # c1: [L1]          → L1 attributed to c1
      # c2: [L1, L2]      → L1 still c1, L2 to c2
      # c3: [L1, L2, L3]  → L3 to c3
      tmp = RealGit.tmp_dir!("exgit_blame_parity_append")
      RealGit.init!(tmp)

      write_and_commit(tmp, "f.txt", "L1\n", "one")
      write_and_commit(tmp, "f.txt", "L1\nL2\n", "two")
      write_and_commit(tmp, "f.txt", "L1\nL2\nL3\n", "three")

      assert_parity(tmp, "f.txt")

      on_exit_cleanup(tmp)
    end

    test "modification in middle" do
      # c1: [A, B, C]
      # c2: [A, X, C]    → B → C replacement
      # c3: [A, X, C, D]
      tmp = RealGit.tmp_dir!("exgit_blame_parity_mod")
      RealGit.init!(tmp)

      write_and_commit(tmp, "f.txt", "A\nB\nC\n", "initial")
      write_and_commit(tmp, "f.txt", "A\nX\nC\n", "replace B with X")
      write_and_commit(tmp, "f.txt", "A\nX\nC\nD\n", "append D")

      assert_parity(tmp, "f.txt")

      on_exit_cleanup(tmp)
    end

    test "insertion between existing lines" do
      tmp = RealGit.tmp_dir!("exgit_blame_parity_insert")
      RealGit.init!(tmp)

      write_and_commit(tmp, "f.txt", "alpha\ngamma\n", "v1")
      write_and_commit(tmp, "f.txt", "alpha\nbeta\ngamma\n", "v2 insert beta")

      assert_parity(tmp, "f.txt")

      on_exit_cleanup(tmp)
    end

    test "deletion with surviving context" do
      tmp = RealGit.tmp_dir!("exgit_blame_parity_del")
      RealGit.init!(tmp)

      write_and_commit(tmp, "f.txt", "A\nB\nC\nD\n", "v1")
      write_and_commit(tmp, "f.txt", "A\nC\nD\n", "v2 delete B")

      assert_parity(tmp, "f.txt")

      on_exit_cleanup(tmp)
    end

    test "many small commits on a growing file" do
      tmp = RealGit.tmp_dir!("exgit_blame_parity_many")
      RealGit.init!(tmp)

      # 10 commits each adding one line.
      for i <- 1..10 do
        content =
          1..i
          |> Enum.map_join("", &"line #{&1}\n")

        write_and_commit(tmp, "f.txt", content, "commit #{i}")
      end

      assert_parity(tmp, "f.txt")

      on_exit_cleanup(tmp)
    end

    test "file at second path works too" do
      tmp = RealGit.tmp_dir!("exgit_blame_parity_nested")
      RealGit.init!(tmp)

      write_and_commit(tmp, "src/lib.ex", "defmodule A do\nend\n", "init")
      write_and_commit(tmp, "src/lib.ex", "defmodule A do\n  def x, do: 1\nend\n", "add x")

      assert_parity(tmp, "src/lib.ex")

      on_exit_cleanup(tmp)
    end

    test "lines shared between first and last are attributed to first" do
      # A line that survives the entire history should be
      # attributed to its introducing commit, not to anything
      # later — even if surrounded by later changes.
      tmp = RealGit.tmp_dir!("exgit_blame_parity_survivor")
      RealGit.init!(tmp)

      write_and_commit(tmp, "f.txt", "SURVIVOR\nother1\n", "c1")
      write_and_commit(tmp, "f.txt", "SURVIVOR\nother2\n", "c2")
      write_and_commit(tmp, "f.txt", "SURVIVOR\nother3\n", "c3")

      # This test asserts PARITY: whatever git blame says for
      # line 1, exgit must agree. (Note: git's blame heuristics
      # can surprise — when multiple commits have identical
      # timestamps, attribution order within a block can be
      # non-deterministic in subtle ways, so we test the weaker
      # claim of matching git rather than asserting c1.)
      assert_parity(tmp, "f.txt")

      on_exit_cleanup(tmp)
    end
  end

  # --- Helpers ---

  defp assert_parity(tmp, path) do
    git_attribs = git_blame_first_parent(tmp, path)
    {:ok, exgit_entries, _} = exgit_blame(tmp, path)

    assert length(exgit_entries) == length(git_attribs),
           "Line count mismatch: exgit=#{length(exgit_entries)} git=#{length(git_attribs)}"

    mismatches =
      exgit_entries
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {entry, i} ->
        git_sha = Enum.at(git_attribs, i - 1)
        exgit_sha = Base.encode16(entry.commit_sha, case: :lower)

        if git_sha == exgit_sha do
          []
        else
          [
            %{
              line: i,
              text: entry.line,
              git: git_sha,
              exgit: exgit_sha
            }
          ]
        end
      end)

    assert mismatches == [], """
    Blame attribution mismatches in #{path}:
    #{format_mismatches(mismatches)}
    """
  end

  defp format_mismatches(mismatches) do
    Enum.map_join(mismatches, "\n", fn m ->
      "  line #{m.line} #{inspect(m.text)}: git=#{short(m.git)} exgit=#{short(m.exgit)}"
    end)
  end

  defp short(sha), do: String.slice(sha, 0, 10)

  defp write_and_commit(tmp, path, content, message) do
    full = Path.join(tmp, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    RealGit.git!(tmp, ["add", "-A"])
    RealGit.git!(tmp, ["commit", "-m", message])
  end

  # Parse `git blame --porcelain --first-parent` output. Returns a
  # list of hex commit SHAs indexed by line number (1-based →
  # list position 0).
  #
  # Porcelain format: each line group starts with
  #   "<40-hex sha> <orig_line> <final_line> [group_size]"
  # followed by key/value metadata lines, then a tab-prefixed
  # content line. Subsequent lines in the same group omit the
  # sha line entirely — we must carry the last-seen sha forward.
  defp git_blame_first_parent(tmp, path) do
    {out, 0} =
      RealGit.git!(tmp, ["blame", "--porcelain", "--first-parent", path])

    {result, _} =
      out
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {acc, current_sha} ->
        cond do
          Regex.match?(~r/^[0-9a-f]{40} \d+ \d+/, line) ->
            [sha | _] = String.split(line, " ", parts: 2)
            {acc, sha}

          String.starts_with?(line, "\t") ->
            {[current_sha | acc], current_sha}

          true ->
            {acc, current_sha}
        end
      end)

    Enum.reverse(result)
  end

  defp exgit_blame(tmp, path) do
    object_store = ObjectStore.Disk.new(Path.join(tmp, ".git"))
    ref_store = Exgit.RefStore.Disk.new(Path.join(tmp, ".git"))
    repo = Repository.new(object_store, ref_store)

    Exgit.Blame.blame(repo, "HEAD", path)
  end

  defp git_rev_parse(tmp, ref) do
    {out, 0} = RealGit.git!(tmp, ["rev-parse", ref])
    String.trim(out)
  end

  defp on_exit_cleanup(tmp) do
    on_exit(fn -> File.rm_rf!(tmp) end)
  end
end
