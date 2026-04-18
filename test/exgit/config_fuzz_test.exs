defmodule Exgit.ConfigFuzzTest do
  @moduledoc """
  Property tests for `Exgit.Config.parse/1`. The parser's contract is:

    * never raises on any bytes (caller- or fs-supplied input)
    * always returns `{:ok, %Config{}}` or `{:error, _}`
    * a parse → encode → parse roundtrip is a fixpoint for any
      initial `{:ok, _}` result

  Exercised with random bytes AND with structurally-plausible-
  looking inputs (headers, keys, values, comments) to cover both
  bytewise-hostile and syntactically-confusing cases.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.Config

  @doc false
  def alnum, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 16)

  describe "never raises" do
    property "on random bytes" do
      check all(bytes <- StreamData.binary(max_length: 512), max_runs: 500) do
        # Parse MUST NOT raise regardless of input shape.
        result = Config.parse(bytes)
        assert match?({:ok, %Config{}}, result) or match?({:error, _}, result)
      end
    end

    property "on section-header-like noise" do
      check all(
              section <- alnum(),
              sub <- StreamData.one_of([StreamData.constant(nil), alnum()]),
              pairs <- StreamData.list_of(StreamData.tuple({alnum(), alnum()}), max_length: 8)
            ) do
        text =
          case sub do
            nil -> "[#{section}]\n"
            s -> "[#{section} \"#{s}\"]\n"
          end <>
            Enum.map_join(pairs, "\n", fn {k, v} -> "\t#{k} = #{v}" end)

        assert {:ok, %Config{}} = Config.parse(text)
      end
    end
  end

  describe "roundtrip" do
    property "parse → encode → parse is a fixpoint for any parseable input" do
      check all(
              section <- alnum(),
              sub <- StreamData.one_of([StreamData.constant(nil), alnum()]),
              pairs <- StreamData.list_of(StreamData.tuple({alnum(), alnum()}), max_length: 4)
            ) do
        initial =
          Enum.reduce(pairs, Config.new(), fn {k, v}, c ->
            Config.set(c, section, sub, k, v)
          end)

        emitted = initial |> Config.encode() |> IO.iodata_to_binary()
        assert {:ok, reparsed} = Config.parse(emitted)
        # We round-trip section+subsection keys case-normalized
        # (downcased section), so compare the normalized form.
        assert reparsed.sections == initial.sections
      end
    end
  end

  describe "no RCE-shaped values leak" do
    # A hostile .git/config value should parse cleanly. We don't
    # care what it contains — we just want proof that the parser
    # doesn't do anything with it (no exec, no path expansion).
    #
    # These are strings git itself would act on via core.fsmonitor /
    # core.sshCommand. We parse them and assert the value is
    # stored verbatim, proving we're not normalizing or
    # interpreting.
    test "core.fsmonitor path is stored as an opaque string" do
      text = """
      [core]
      \tfsmonitor = /usr/bin/evil --payload
      """

      {:ok, c} = Config.parse(text)
      assert Config.get(c, "core", nil, "fsmonitor") == "/usr/bin/evil --payload"
    end

    test "core.sshCommand is stored as an opaque string" do
      text = """
      [core]
      \tsshCommand = ssh -oProxyCommand=touch /tmp/pwned
      """

      {:ok, c} = Config.parse(text)

      assert Config.get(c, "core", nil, "sshCommand") ==
               "ssh -oProxyCommand=touch /tmp/pwned"
    end

    test "includeIf path is parsed but not expanded" do
      text = """
      [includeIf "gitdir:~/evil"]
      \tpath = /etc/passwd
      """

      assert {:ok, c} = Config.parse(text)
      # Value is stored; no include expansion happens.
      assert Config.get(c, "includeif", "gitdir:~/evil", "path") == "/etc/passwd"
    end
  end
end
