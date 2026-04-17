defmodule Exgit.ConfigParsingTest do
  use ExUnit.Case, async: true

  alias Exgit.Config

  describe "quoted value parsing (P0.20)" do
    test ~S|foo = "hello world"  →  "hello world"| do
      {:ok, c} = Config.parse(~s([core]\n\tfoo = "hello world"\n))
      assert Config.get(c, "core", nil, "foo") == "hello world"
    end

    test ~S|foo = "a\"b"  →  a"b| do
      raw = "[core]\n\tfoo = \"a\\\"b\"\n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == ~s(a"b)
    end

    test ~S|foo = "line with \\n escape"  →  newline| do
      raw = "[core]\n\tfoo = \"line\\nbreak\"\n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == "line\nbreak"
    end

    test ~S|foo = "tab\tchar"  →  "tab\tchar"| do
      raw = "[core]\n\tfoo = \"tab\\tchar\"\n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == "tab\tchar"
    end

    test "partially-quoted value: foo = pre\"mid\"post → premidpost" do
      raw = "[core]\n\tfoo = pre\"mid\"post\n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == "premidpost"
    end

    test "inline comment without preceding whitespace: foo = bar;cmt → bar" do
      raw = "[core]\n\tfoo = bar;cmt\n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == "bar"
    end

    test "quoted value containing an inline-comment char is preserved" do
      # The `#` inside quotes must NOT start a comment.
      raw = "[core]\n\tfoo = \"value # not comment\"\n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == "value # not comment"
    end

    test "value with only leading whitespace preserved when quoted" do
      raw = "[core]\n\tfoo = \"  leading\"\n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == "  leading"
    end

    test "unquoted trailing whitespace is stripped" do
      raw = "[core]\n\tfoo = trimmed   \n"
      {:ok, c} = Config.parse(raw)
      assert Config.get(c, "core", nil, "foo") == "trimmed"
    end
  end

  describe "include directives (P3.4)" do
    test "[include] section parses and the include path is exposed via get/4" do
      # We don't (yet) resolve includes, but we MUST expose that an
      # [include] section existed so callers that need it can handle it.
      raw =
        """
        [include]
        \tpath = ~/.gitconfig-nothing-here
        [core]
        \tfoo = bar
        """

      {:ok, c} = Config.parse(raw)

      # The include path must be present in the parsed config.
      assert Config.get(c, "include", nil, "path") == "~/.gitconfig-nothing-here"

      # Other sections are still parsable — parse didn't silently drop them.
      assert Config.get(c, "core", nil, "foo") == "bar"
    end

    test "[includeIf ...] with a path is exposed with its subsection key" do
      raw =
        """
        [includeIf "gitdir:~/work/"]
        \tpath = ~/.gitconfig-work
        """

      {:ok, c} = Config.parse(raw)

      assert Config.get(c, "includeif", "gitdir:~/work/", "path") == "~/.gitconfig-work"
    end
  end

  describe "multi-valued add (P3.5)" do
    test "Config.add/5 adds a value without replacing existing ones" do
      # The basic `set` replaces; `add` appends.
      c =
        Config.new()
        |> Config.add("remote", "origin", "fetch", "+refs/heads/main:refs/remotes/origin/main")
        |> Config.add("remote", "origin", "fetch", "+refs/heads/dev:refs/remotes/origin/dev")

      vals = Config.get_all(c, "remote", "origin", "fetch")

      assert "+refs/heads/main:refs/remotes/origin/main" in vals
      assert "+refs/heads/dev:refs/remotes/origin/dev" in vals
      assert length(vals) == 2
    end
  end
end
