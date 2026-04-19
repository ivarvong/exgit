defmodule Exgit.FSReadLinesParityTest do
  @moduledoc """
  Parity test: `FS.read_lines(repo, ref, path, range)` returns the
  same lines that real `git show REF:path | sed -n 'L1,L2p'`
  returns for the same inputs.

  We exercise:

    * single-line reads
    * ranges entirely within the file
    * ranges that overshoot EOF
    * ranges past EOF (should return empty)
    * files with and without trailing newlines

  Line numbering convention must match git's `show` + sed's
  default behavior (1-indexed, trailing `\\n` doesn't create a
  phantom empty line).

  Tagged `:real_git` and `:slow`; excluded from default tier.
  """

  use ExUnit.Case, async: false

  @moduletag :real_git
  @moduletag :slow

  alias Exgit.ObjectStore
  alias Exgit.Repository
  alias Exgit.Test.RealGit

  @cases [
    {"decad.txt", 1},
    {"decad.txt", 5},
    {"decad.txt", 10},
    {"decad.txt", {3, 5}},
    {"decad.txt", {1, 10}},
    {"decad.txt", {8, 100}},
    {"decad.txt", {50, 100}},
    {"no_trail.txt", 3},
    {"no_trail.txt", {1, 10}},
    {"readme.md", {1, 3}}
  ]

  setup do
    tmp = RealGit.tmp_dir!("exgit_read_lines_parity")
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

  for {path, range} <- @cases do
    test "path=#{inspect(path)} range=#{inspect(range)}", %{tmp: tmp, repo: repo} do
      path = unquote(path)
      range = unquote(Macro.escape(range))

      git_lines = git_show_sed(tmp, path, range)
      exgit_lines = exgit_read_lines(repo, path, range)

      assert exgit_lines == git_lines, """
      read_lines parity mismatch for path=#{inspect(path)} range=#{inspect(range)}:

      git (via show + sed):
      #{format(git_lines)}

      exgit:
      #{format(exgit_lines)}
      """
    end
  end

  # Run `git show HEAD:<path> | sed -n 'START,ENDp'` and return a
  # list of {line_number, line_text} tuples.
  defp git_show_sed(tmp, path, range) do
    {start_l, end_l} =
      case range do
        n when is_integer(n) -> {n, n}
        {a, b} -> {a, b}
      end

    # Use `git show` piped into `sed` directly.
    sed_expr = "#{start_l},#{end_l}p"

    case System.cmd("sh", ["-c", "git show HEAD:#{path} | sed -n '#{sed_expr}'"], cd: tmp) do
      {"", 0} ->
        []

      {out, 0} ->
        # sed typically emits a trailing `\n` after each printed line.
        # For a file with no trailing newline whose last line we're
        # printing, sed emits the content without a trailing \n. Handle
        # both by trimming a single trailing \n and splitting.
        trimmed =
          case String.ends_with?(out, "\n") do
            true -> binary_part(out, 0, byte_size(out) - 1)
            false -> out
          end

        trimmed
        |> String.split("\n")
        |> Enum.with_index(start_l)
        |> Enum.map(fn {line, idx} -> {idx, line} end)

      {err, _} ->
        flunk("git show | sed failed for #{path} #{inspect(range)}: #{err}")
    end
  end

  defp exgit_read_lines(repo, path, range) do
    elixir_range =
      case range do
        n when is_integer(n) -> n
        {a, b} when a <= b -> a..b
        {a, b} -> a..b//-1
      end

    case Exgit.FS.read_lines(repo, "HEAD", path, elixir_range) do
      {:ok, lines, _repo} -> lines
      {:error, reason} -> flunk("exgit read_lines failed: #{inspect(reason)}")
    end
  end

  defp format([]), do: "  (none)"

  defp format(lines) do
    Enum.map_join(lines, "\n", fn {n, line} -> "    #{n}: #{inspect(line)}" end)
  end

  defp files do
    [
      {"decad.txt", Enum.map_join(1..10, "\n", &"line #{&1}") <> "\n"},
      {"no_trail.txt", "a\nb\nc"},
      {"readme.md",
       """
       # Hello
       Body line 1.
       Body line 2.
       """}
    ]
  end
end
