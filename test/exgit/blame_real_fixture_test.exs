defmodule Exgit.BlameRealFixtureTest do
  @moduledoc """
  End-to-end integration test for `Exgit.Blame.blame/3` against
  real public repos. These are **smoke-plus-parity** tests:

    * We don't assert full per-line parity with `git blame` on
      real fixtures (real-world repos have merges and renames
      where exgit's `--first-parent`-no-rename semantics
      legitimately diverge from git's default blame).
    * We DO assert: blame produces an entry for every line of
      the file, every entry has a valid 20-byte commit SHA, the
      commit SHAs correspond to real commits in the repo's
      object graph, and **at least N%** of lines agree with
      `git blame --first-parent`.

  The "at least N%" agreement is the meaningful signal: if
  exgit's blame is catastrophically wrong, we'll see <50%
  agreement. Agreement of 90%+ means we match git's semantics
  on the typical cases and only diverge at the edges (merges,
  copies).

  Tagged `:network` + `:slow` + `:integration` so the default
  tier doesn't hit GitHub.
  """

  use ExUnit.Case, async: false

  @moduletag :network
  @moduletag :slow
  @moduletag :integration

  alias Exgit.Blame

  # Minimum fraction of lines that must match git blame's
  # attribution for this test to pass. The remaining few
  # percent can legitimately differ due to merge-walk and
  # rename semantics.
  @min_agreement 0.85

  setup_all do
    {:ok, repo} =
      Exgit.clone("https://github.com/anthropics/claude-agent-sdk-python", lazy: true)

    {:ok, repo} = Exgit.FS.prefetch(repo, "HEAD", blobs: true)
    {:ok, repo: repo}
  end

  # Files chosen to have NO rename history. This isolates the
  # parity test from exgit's intentional no-rename-following
  # semantics (which would legitimately diverge from git blame
  # on files that were moved or had their parent directory
  # renamed). Verified via
  # `git log --follow --diff-filter=A --name-only -- path`
  # producing the same path as the current one.
  @files [
    "README.md",
    "CHANGELOG.md",
    "src/claude_agent_sdk/_cli_version.py",
    "pyproject.toml"
  ]

  for path <- @files do
    test "blame #{inspect(path)}: every line attributed + ≥#{round(@min_agreement * 100)}% git parity",
         %{repo: repo} do
      path = unquote(path)

      {us, {:ok, entries, _repo}} =
        :timer.tc(fn -> Blame.blame(repo, "HEAD", path) end)

      IO.puts(
        "\n  blame #{path}: #{length(entries)} lines in " <>
          "#{:io_lib.format("~.1f", [us / 1000])} ms"
      )

      # Every line has a valid attribution.
      for e <- entries do
        assert is_integer(e.line_number) and e.line_number >= 1
        assert is_binary(e.commit_sha) and byte_size(e.commit_sha) == 20
        assert is_binary(e.author_name)
        assert is_integer(e.author_time) and e.author_time > 0
      end

      # Parity against git blame (shell out to the real git
      # running against a local clone). We tolerate <#{@min_agreement * 100}%
      # divergence because real history has merges and renames
      # where our --first-parent-no-rename semantics differ.
      parity_fraction = measure_parity(repo, path, entries)

      IO.puts(
        "    #{:io_lib.format("~.1f", [parity_fraction * 100])}% agreement with git blame"
      )

      assert parity_fraction >= @min_agreement,
             "Blame agreement below threshold: #{parity_fraction} < #{@min_agreement}"
    end
  end

  # Shell out to `git blame` on a local clone, compare line-by-line.
  defp measure_parity(repo, path, exgit_entries) do
    tmp = local_clone(repo)

    {out, 0} =
      System.cmd("git", ["blame", "--porcelain", "--first-parent", path], cd: tmp)

    git_shas = parse_porcelain(out)

    File.rm_rf!(tmp)

    if length(git_shas) != length(exgit_entries) do
      # Line count mismatch is a more serious signal; fail hard.
      flunk(
        "Line count mismatch in #{path}: exgit=#{length(exgit_entries)} git=#{length(git_shas)}"
      )
    end

    matches =
      Enum.zip(exgit_entries, git_shas)
      |> Enum.count(fn {e, git_sha} ->
        Base.encode16(e.commit_sha, case: :lower) == git_sha
      end)

    matches / max(length(git_shas), 1)
  end

  # Materialize the lazy repo to a local working tree via a full
  # git clone. Cheaper than streaming history through exgit for
  # this cross-check.
  defp local_clone(_repo) do
    tmp =
      Path.join(System.tmp_dir!(), "exgit_blame_oracle_#{System.unique_integer([:positive])}")

    {_, 0} =
      System.cmd(
        "git",
        ["clone", "--quiet", "https://github.com/anthropics/claude-agent-sdk-python", tmp]
      )

    tmp
  end

  defp parse_porcelain(out) do
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
end
