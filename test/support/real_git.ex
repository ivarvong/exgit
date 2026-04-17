defmodule Exgit.Test.RealGit do
  @moduledoc """
  Helpers for driving a real `git` binary to produce fixtures. Used only in
  dev/test where `git` is on PATH. Tests that depend on this should tag
  `@moduletag :real_git` and skip if unavailable.
  """

  @doc "Returns true when a git binary is available on PATH."
  def available? do
    case System.find_executable("git") do
      nil -> false
      _ -> true
    end
  end

  @doc "Create a fresh empty temporary directory."
  def tmp_dir!(prefix \\ "exgit_rg") do
    base =
      Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(base)
    base
  end

  @doc """
  Run git with the given args in `cwd`. Returns `{stdout, status}`. Raises
  on non-zero status unless `allow_error: true`.
  """
  def git!(cwd, args, opts \\ []) do
    env =
      [
        {"GIT_AUTHOR_NAME", "Ex Git"},
        {"GIT_AUTHOR_EMAIL", "ex@git.test"},
        {"GIT_COMMITTER_NAME", "Ex Git"},
        {"GIT_COMMITTER_EMAIL", "ex@git.test"},
        {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00+0000"},
        {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00+0000"}
      ] ++ Keyword.get(opts, :env, [])

    {out, status} =
      System.cmd("git", args, cd: cwd, env: env, stderr_to_stdout: true)

    if status != 0 and not Keyword.get(opts, :allow_error, false) do
      raise "git #{Enum.join(args, " ")} failed (#{status}):\n#{out}"
    end

    {out, status}
  end

  @doc """
  Run `git` and pipe `input` to stdin. Returns `{stdout, status}`.
  """
  def git_stdin!(cwd, args, input, opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "exgit_rg_stdin_#{System.unique_integer([:positive])}")
    File.write!(tmp, input)

    try do
      shell =
        Enum.join(
          ["git" | Enum.map(args, &shell_escape/1)],
          " "
        ) <> " < " <> shell_escape(tmp)

      env =
        [
          {"GIT_AUTHOR_NAME", "Ex Git"},
          {"GIT_AUTHOR_EMAIL", "ex@git.test"},
          {"GIT_COMMITTER_NAME", "Ex Git"},
          {"GIT_COMMITTER_EMAIL", "ex@git.test"},
          {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00+0000"},
          {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00+0000"}
        ] ++ Keyword.get(opts, :env, [])

      {out, status} = System.cmd("sh", ["-c", shell], cd: cwd, env: env, stderr_to_stdout: true)

      if status != 0 and not Keyword.get(opts, :allow_error, false) do
        raise "git #{Enum.join(args, " ")} failed (#{status}):\n#{out}"
      end

      {out, status}
    after
      File.rm(tmp)
    end
  end

  @doc "Initialize a bare repo at path."
  def init_bare!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "--bare", "--initial-branch=main", "-q"])
    path
  end

  @doc "Initialize a normal repo at path."
  def init!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "--initial-branch=main", "-q"])
    path
  end

  @doc "hash-object -w: write a blob and return its 40-char sha."
  def write_blob!(cwd, data) do
    {out, _} = git_stdin!(cwd, ["hash-object", "-w", "--stdin"], data)
    String.trim(out)
  end

  @doc "read-tree → write-tree given a list of {mode, path, sha}. Returns tree sha."
  def write_tree!(cwd, entries) do
    mkfile =
      entries
      |> Enum.map(fn {mode, path, sha} -> "#{mode} blob #{sha}\t#{path}\n" end)
      |> Enum.join()

    {out, _} = git_stdin!(cwd, ["mktree"], mkfile)
    String.trim(out)
  end

  @doc """
  Build a commit object. `opts`:
    - :tree (required) — 40-char sha
    - :parents — list of 40-char parents
    - :message — string (default \"msg\\n\")
  """
  def commit_tree!(cwd, opts) do
    tree = Keyword.fetch!(opts, :tree)
    parents = Keyword.get(opts, :parents, [])
    message = Keyword.get(opts, :message, "msg\n")

    args = ["commit-tree", tree]
    args = Enum.reduce(parents, args, fn p, acc -> acc ++ ["-p", p] end)

    {out, _} = git_stdin!(cwd, args, message)
    String.trim(out)
  end

  @doc "Return raw loose-object bytes (compressed) from .git/objects/xx/yyyy…"
  def read_loose!(repo_dir, sha) when is_binary(sha) do
    dir =
      cond do
        File.dir?(Path.join(repo_dir, "objects")) -> repo_dir
        true -> Path.join(repo_dir, ".git")
      end

    <<a::binary-size(2), b::binary>> = sha
    path = Path.join([dir, "objects", a, b])
    File.read!(path)
  end

  @doc "Hex SHA → binary 20-byte SHA."
  def hex_to_bin(hex) do
    {:ok, bin} = Base.decode16(hex, case: :mixed)
    bin
  end

  @doc "Binary SHA → lowercase hex."
  def bin_to_hex(bin), do: Base.encode16(bin, case: :lower)

  defp shell_escape(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
