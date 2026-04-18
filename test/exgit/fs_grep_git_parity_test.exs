defmodule Exgit.FSGrepGitParityTest do
  @moduledoc """
  Correctness oracle: for a given repo + pattern, `Exgit.FS.grep`
  must find the same set of `(path, line_number)` matches that
  `git grep -n` finds. The library's advertised value is "faster
  than shelling out to `git`"; parity with git's output is what
  makes that claim credible.

  We check **set equality** on `(path, line_number)` pairs, not
  byte-equal line text — there are subtle differences in how
  git vs our library handle trailing-newlines / BOM / etc. that
  aren't relevant to whether "search found the right matches."
  A full byte-equal check would be strictly stronger but rejects
  equivalences we accept.

  Tagged `:real_git` because it shells out to `git`; tagged
  `:slow` because we run ~20 pattern variants.
  """

  use ExUnit.Case, async: false
  @moduletag :real_git
  @moduletag :slow

  alias Exgit.ObjectStore
  alias Exgit.Repository
  alias Exgit.Test.RealGit

  # A handful of representative patterns. Each should match in
  # the seed repo (below) at ZERO or more files.
  @patterns [
    "defmodule",
    "def ",
    "do:",
    "@moduledoc",
    "TODO",
    "xyznomatch",
    "end"
  ]

  setup do
    # Build a real git repo with some diverse content:
    # - Elixir-looking source with modules, functions, comments
    # - A README
    # - A file with a long line
    # - A binary-like file (should NOT match text patterns)
    tmp = RealGit.tmp_dir!("exgit_grep_parity")
    RealGit.init!(tmp)

    Enum.each(files_to_create(), fn {path, content} ->
      full = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    RealGit.git!(tmp, ["add", "-A"])
    RealGit.git!(tmp, ["commit", "-m", "initial"])

    # Load the same repo state into exgit from disk.
    object_store = ObjectStore.Disk.new(Path.join(tmp, ".git"))
    ref_store = Exgit.RefStore.Disk.new(Path.join(tmp, ".git"))
    repo = Repository.new(object_store, ref_store)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, repo: repo}
  end

  describe "Exgit.FS.grep matches git grep" do
    for pattern <- @patterns do
      test "pattern: #{inspect(pattern)}", %{tmp: tmp, repo: repo} do
        git_matches = git_grep(tmp, unquote(pattern))
        exgit_matches = exgit_grep(repo, unquote(pattern))

        # Compute set differences so a mismatch report is
        # actionable.
        git_only = MapSet.difference(git_matches, exgit_matches)
        exgit_only = MapSet.difference(exgit_matches, git_matches)

        assert MapSet.size(git_only) == 0 and MapSet.size(exgit_only) == 0, """
        Parity mismatch for pattern #{inspect(unquote(pattern))}:

        git grep found (not in exgit):
        #{format_matches(git_only)}

        exgit found (not in git):
        #{format_matches(exgit_only)}
        """
      end
    end
  end

  # Helpers

  defp git_grep(tmp, pattern) do
    # `git grep -n --no-color -I -- pattern HEAD` prints:
    #   HEAD:path/to/file:lineno:matched line
    # `-I` skips binary files; matches what Exgit.FS.grep does
    # via binary_content?/1 heuristic.
    case RealGit.git!(tmp, ["grep", "-n", "--no-color", "-I", pattern, "HEAD"], allow_error: true) do
      {"", 1} ->
        # Exit 1 means "no matches" — treat as empty set.
        MapSet.new()

      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_git_grep_line/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
    end
  end

  defp parse_git_grep_line(line) do
    case String.split(line, ":", parts: 4) do
      [_head, path, lineno, _text] ->
        {path, String.to_integer(lineno)}

      _ ->
        nil
    end
  end

  defp exgit_grep(repo, pattern) do
    repo
    |> Exgit.FS.grep("HEAD", pattern)
    |> Enum.map(&{&1.path, &1.line_number})
    |> MapSet.new()
  end

  defp format_matches(set) do
    case MapSet.size(set) do
      0 ->
        "  (none)"

      _ ->
        set
        |> Enum.take(20)
        |> Enum.sort()
        |> Enum.map_join("\n", fn {p, l} -> "    #{p}:#{l}" end)
    end
  end

  defp files_to_create do
    [
      {"README.md",
       """
       # Hello

       This is the README.
       TODO: write documentation.
       """},
      {"lib/a.ex",
       """
       defmodule A do
         @moduledoc "First module"

         def hello, do: :world

         def compute(x, y) do
           x + y
         end
       end
       """},
      {"lib/b.ex",
       """
       defmodule B do
         def run do
           # TODO: implement
           :ok
         end
       end
       """},
      {"test/a_test.exs",
       """
       defmodule ATest do
         use ExUnit.Case

         test "works" do
           assert A.hello() == :world
         end
       end
       """},
      {"data/long_line.txt", String.duplicate("abc ", 1000) <> "\nend\n"}
    ]
  end
end
