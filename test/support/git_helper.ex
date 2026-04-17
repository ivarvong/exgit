defmodule Exgit.Test.GitHelper do
  def cmd_with_stdin(command, args, input, opts \\ []) do
    cd = Keyword.get(opts, :cd)
    env = Keyword.get(opts, :env, [])

    tmp = Path.join(System.tmp_dir!(), "exgit_stdin_#{System.unique_integer([:positive])}")
    File.write!(tmp, input)

    script =
      Enum.join([shell_escape(command) | Enum.map(args, &shell_escape/1)], " ") <>
        " < " <> shell_escape(tmp)

    cmd_opts = []
    cmd_opts = if cd, do: [{:cd, cd} | cmd_opts], else: cmd_opts
    cmd_opts = if env != [], do: [{:env, env} | cmd_opts], else: cmd_opts

    {output, status} = System.cmd("sh", ["-c", script], cmd_opts)
    File.rm(tmp)
    {output, status}
  end

  defp shell_escape(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
