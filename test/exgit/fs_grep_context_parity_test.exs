defmodule Exgit.FSGrepContextParityTest do
  @moduledoc """
  Parity test for `Exgit.FS.grep(..., context: N)` against real
  `git grep -n -C N`.

  `git grep -C` emits one line per match AND per context line, in
  a unified stream per file, tagged with `:` for match lines and
  `-` for context lines:

      HEAD:path-4-  context before
      HEAD:path:5:  match
      HEAD:path-6-  context after

  We reconstruct the `{path, line_number, kind}` set from git's
  output and compare against exgit's context results.

  `exgit` emits one row per match with separate `context_before`
  and `context_after` lists. To compare, we flatten each exgit
  row into the union `{path, line_number, :match_or_context}`
  and require set-equivalence with git's output.

  Caveats (mirrored from `fs_grep_git_parity_test`):

    * `git grep -C` merges overlapping context of nearby matches
      into a single block (no duplicate line emissions). exgit's
      API returns one row per match with its own context; when
      flattened into a set of `(path, line)` tuples, overlapping
      context collapses naturally via `MapSet`.
    * We assert set-equality on `{path, line_number}` tuples for
      the union of matches+context. This is the meaningful
      correctness claim: "asking for context N surfaces the same
      lines that git would surface." Tagging the kind separately
      would over-specify when exgit chooses to represent an
      overlap row as context-of-one-match vs. match-of-another.

  Tagged `:real_git` and `:slow` to keep the default test tier
  fast.
  """

  use ExUnit.Case, async: false

  @moduletag :real_git
  @moduletag :slow

  alias Exgit.ObjectStore
  alias Exgit.Repository
  alias Exgit.Test.RealGit

  @cases [
    {"target", 0},
    {"target", 1},
    {"target", 2},
    {"target", 5},
    {"one", 3},
    {"def ", 2}
  ]

  setup do
    tmp = RealGit.tmp_dir!("exgit_grep_ctx_parity")
    RealGit.init!(tmp)

    Enum.each(files(), fn {path, content} ->
      full = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    RealGit.git!(tmp, ["add", "-A"])
    RealGit.git!(tmp, ["commit", "-m", "initial"])

    object_store = ObjectStore.Disk.new(Path.join(tmp, ".git"))
    ref_store = Exgit.RefStore.Disk.new(Path.join(tmp, ".git"))
    repo = Repository.new(object_store, ref_store)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, repo: repo}
  end

  describe "context set-equality with git grep -C" do
    for {pattern, n} <- @cases do
      test "pattern=#{inspect(pattern)} context=#{n}",
           %{tmp: tmp, repo: repo} do
        pat = unquote(pattern)
        n = unquote(n)

        git_set = git_grep_union(tmp, pat, n)
        exgit_set = exgit_grep_union(repo, pat, n)

        git_only = MapSet.difference(git_set, exgit_set)
        exgit_only = MapSet.difference(exgit_set, git_set)

        assert MapSet.size(git_only) == 0 and MapSet.size(exgit_only) == 0, """
        Context parity mismatch for pattern=#{inspect(pat)} context=#{n}:

        git grep emitted (missing from exgit):
        #{format(git_only)}

        exgit emitted (missing from git):
        #{format(exgit_only)}
        """
      end
    end
  end

  defp git_grep_union(tmp, pattern, n) do
    # `git grep -n --no-color -I -C N pattern HEAD` prints one
    # line per emitted line (match or context), formatted as
    #   HEAD:path:N:match-text    for match lines
    #   HEAD:path-N-context-text  for context lines
    args = ["grep", "-n", "--no-color", "-I", "-C", Integer.to_string(n), pattern, "HEAD"]

    case RealGit.git!(tmp, args, allow_error: true) do
      {"", 1} ->
        MapSet.new()

      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        # Git inserts `--` hunk separators when multiple match blocks
        # in the same file are far enough apart that their context
        # regions don't overlap. Filter them out — they carry no
        # line info.
        |> Enum.reject(&(&1 == "--"))
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
    end
  end

  # Git emits either "HEAD:path:lineno:..." (match) or
  # "HEAD:path-lineno-..." (context). The separator after `path`
  # distinguishes them, but we only care about (path, lineno) for
  # set membership.
  defp parse_line(line) do
    case Regex.run(~r/^HEAD:([^:]+?)[-:](\d+)[-:]/, line) do
      [_, path, lineno] -> {path, String.to_integer(lineno)}
      _ -> nil
    end
  end

  defp exgit_grep_union(repo, pattern, 0) do
    repo
    |> Exgit.FS.grep("HEAD", pattern)
    |> Enum.map(&{&1.path, &1.line_number})
    |> MapSet.new()
  end

  defp exgit_grep_union(repo, pattern, n) do
    results = repo |> Exgit.FS.grep("HEAD", pattern, context: n) |> Enum.to_list()

    for r <- results, reduce: MapSet.new() do
      acc ->
        acc
        |> MapSet.put({r.path, r.line_number})
        |> union_many(r.path, r.context_before)
        |> union_many(r.path, r.context_after)
    end
  end

  defp union_many(set, path, pairs) do
    Enum.reduce(pairs, set, fn {ln, _text}, acc -> MapSet.put(acc, {path, ln}) end)
  end

  defp format(set) do
    case MapSet.size(set) do
      0 ->
        "  (none)"

      _ ->
        set
        |> Enum.take(30)
        |> Enum.sort()
        |> Enum.map_join("\n", fn {p, l} -> "    #{p}:#{l}" end)
    end
  end

  defp files do
    [
      {"a.ex",
       """
       defmodule A do
         @moduledoc "first"
         def one, do: 1
         def two, do: 2
         def target, do: :hit
         def four, do: 4
         def five, do: 5
       end
       """},
      {"b.ex",
       """
       defmodule B do
         def first, do: "first target"
         def middle, do: :ok
         def last, do: "last target"
       end
       """},
      {"c.ex", "target\nonly one line after\n"},
      {"many.ex",
       """
       target on line 1
       line 2
       line 3
       line 4
       target on line 5
       line 6
       line 7
       line 8
       target on line 9
       line 10
       """},
      {"README.md",
       """
       Hello, target world.
       Next line.
       """}
    ]
  end
end
