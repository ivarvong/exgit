defmodule Exgit.Security.NoShellExecTest do
  @moduledoc """
  Assertion-by-grep: exgit's `lib/` must contain zero calls to
  shell-exec primitives. This is a structural guard against the
  CVE class the staff-engineering review flagged in the config
  audit — `core.sshCommand`, `core.fsmonitor`, submodule URL
  injection, etc. all require the client to *execute* something
  from config. As long as `lib/` has no `System.cmd`, `Port.open`,
  `:os.cmd`, etc., that whole category is out of scope.

  If this test starts failing, someone has introduced a new
  execution path. Either add a well-reasoned exception (and
  document it in SECURITY.md) or refactor to avoid the shell call.
  """

  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../../lib", __DIR__)

  @forbidden_patterns [
    # Erlang / OTP shell-exec primitives
    {~r/\bSystem\.cmd\s*\(/, "System.cmd/2,3"},
    {~r/\bSystem\.shell\s*\(/, "System.shell/1,2"},
    {~r/:os\.cmd\s*\(/, ":os.cmd/1"},
    {~r/\bPort\.open\s*\(/, "Port.open/2"},
    # Path expansion in library code. Expansion of user-controlled
    # paths is a DoS/traversal vector (ex: ~/.git/config could
    # resolve to somewhere unexpected). We use Path.join with
    # validated components instead.
    {~r/\bPath\.expand\s*\(/, "Path.expand/1,2"},
    {~r/\bPath\.absname\s*\(/, "Path.absname/1,2"}
  ]

  test "lib/ contains no shell-exec primitives" do
    offenders =
      @lib_dir
      |> list_ex_files()
      |> Enum.flat_map(fn path ->
        body = File.read!(path)

        for {pattern, label} <- @forbidden_patterns,
            line_with_match(body, pattern) do
          {path, label, line_with_match(body, pattern)}
        end
      end)

    if offenders != [] do
      flunk("""
      Found shell-exec primitives in lib/. These are forbidden
      by the threat model — see SECURITY.md. Offenders:

      #{Enum.map_join(offenders, "\n", fn {p, l, line} -> "  #{Path.relative_to(p, @lib_dir)}: #{l} at: #{line}" end)}
      """)
    end
  end

  defp list_ex_files(dir) do
    {:ok, entries} = File.ls(dir)

    Enum.flat_map(entries, fn e ->
      full = Path.join(dir, e)

      cond do
        File.dir?(full) -> list_ex_files(full)
        String.ends_with?(e, ".ex") -> [full]
        true -> []
      end
    end)
  end

  defp line_with_match(body, pattern) do
    body
    |> String.split("\n")
    |> Enum.find(fn line ->
      # Skip comment lines — mentioning the pattern name in a doc
      # or comment isn't a shell call.
      not String.starts_with?(String.trim_leading(line), "#") and
        Regex.match?(pattern, line)
    end)
  end
end
