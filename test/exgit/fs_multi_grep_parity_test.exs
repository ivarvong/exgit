defmodule Exgit.FSMultiGrepParityTest do
  @moduledoc """
  Parity test: `FS.multi_grep(repo, ref, patterns)` finds the same
  `{path, line_number}` set that `git grep -e P1 -e P2 ...` finds.

  Exgit's multi_grep emits one row per (pattern, match) — a line
  matched by both patterns produces two rows. When we flatten
  exgit's output into a `{path, line_number}` set, the duplicate
  rows collapse. Git's `-e` union already produces one line per
  `(path, line_number)`. So set-equality on `(path, line_number)`
  is the right oracle.

  Tagged `:real_git` and `:slow`.
  """

  use ExUnit.Case, async: false

  @moduletag :real_git
  @moduletag :slow

  alias Exgit.ObjectStore
  alias Exgit.Repository
  alias Exgit.Test.RealGit

  @pattern_sets [
    ["auth_token", "api_key"],
    ["defmodule", "do"],
    ["def ", "TODO"],
    ["xyznomatch_1", "xyznomatch_2"]
  ]

  setup do
    tmp = RealGit.tmp_dir!("exgit_multi_grep_parity")
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

  describe "multi-pattern union matches git grep -e ..." do
    for patterns <- @pattern_sets do
      test "patterns=#{inspect(patterns)}", %{tmp: tmp, repo: repo} do
        patterns = unquote(patterns)

        git_set = git_multi_grep(tmp, patterns)
        exgit_set = exgit_multi_grep(repo, patterns)

        git_only = MapSet.difference(git_set, exgit_set)
        exgit_only = MapSet.difference(exgit_set, git_set)

        assert MapSet.size(git_only) == 0 and MapSet.size(exgit_only) == 0, """
        Parity mismatch for patterns=#{inspect(patterns)}:

        git grep found (missing from exgit):
        #{format(git_only)}

        exgit found (missing from git):
        #{format(exgit_only)}
        """
      end
    end
  end

  defp git_multi_grep(tmp, patterns) do
    # git grep -n --no-color -I -e P1 -e P2 ... HEAD
    e_args = Enum.flat_map(patterns, fn p -> ["-e", p] end)
    args = ["grep", "-n", "--no-color", "-I"] ++ e_args ++ ["HEAD"]

    case RealGit.git!(tmp, args, allow_error: true) do
      {"", 1} ->
        MapSet.new()

      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_line/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
    end
  end

  defp parse_line(line) do
    case String.split(line, ":", parts: 4) do
      [_head, path, lineno, _text] -> {path, String.to_integer(lineno)}
      _ -> nil
    end
  end

  defp exgit_multi_grep(repo, patterns) do
    # Use list-form (each pattern is its own tag).
    repo
    |> Exgit.FS.multi_grep("HEAD", patterns)
    |> Enum.map(&{&1.path, &1.line_number})
    |> MapSet.new()
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
      {"lib/auth.ex",
       """
       defmodule Auth do
         @auth_token System.get_env("AUTH_TOKEN")
         @api_key System.get_env("API_KEY")

         def check, do: :ok

         def login(user) do
           # TODO: rate-limit
           {:ok, user}
         end
       end
       """},
      {"lib/mixed.ex",
       """
       # both auth_token AND api_key appear here
       defmodule Mixed do
         @creds {@auth_token, @api_key}
       end
       """},
      {"lib/logging.ex",
       """
       defmodule Logging do
         # no secrets here — just logs
         def info(msg), do: IO.puts(msg)
         def debug(msg), do: IO.inspect(msg)
       end
       """},
      {"README.md",
       """
       # Project

       TODO: document auth_token handling.
       """}
    ]
  end
end
