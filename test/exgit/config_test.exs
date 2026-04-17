defmodule Exgit.ConfigTest do
  use ExUnit.Case, async: true

  alias Exgit.Config

  describe "parse/1 and encode/1" do
    test "parses a basic config" do
      text = """
      [core]
      \trepositoryformatversion = 0
      \tfilemode = true
      \tbare = true
      """

      assert {:ok, config} = Config.parse(text)
      assert Config.get(config, "core", "repositoryformatversion") == "0"
      assert Config.get(config, "core", "bare") == "true"
    end

    test "parses subsections" do
      text = """
      [remote "origin"]
      \turl = https://github.com/test/repo.git
      \tfetch = +refs/heads/*:refs/remotes/origin/*
      """

      assert {:ok, config} = Config.parse(text)
      assert Config.get(config, "remote", "origin", "url") == "https://github.com/test/repo.git"
    end

    test "handles comments and blank lines" do
      text = """
      # This is a comment
      ; Another comment

      [core]
      \tbare = true
      """

      assert {:ok, config} = Config.parse(text)
      assert Config.get(config, "core", "bare") == "true"
    end

    test "keys are case-insensitive" do
      text = "[core]\n\tBare = true\n"
      assert {:ok, config} = Config.parse(text)
      assert Config.get(config, "core", "bare") == "true"
    end

    test "boolean keys (no = sign)" do
      text = "[core]\n\tbare\n"
      assert {:ok, config} = Config.parse(text)
      assert Config.get(config, "core", "bare") == "true"
    end

    test "round-trips through encode" do
      config =
        Config.new()
        |> Config.set("core", nil, "bare", "true")
        |> Config.set("remote", "origin", "url", "https://example.com/repo.git")

      encoded = config |> Config.encode() |> IO.iodata_to_binary()
      assert {:ok, parsed} = Config.parse(encoded)
      assert Config.get(parsed, "core", "bare") == "true"
      assert Config.get(parsed, "remote", "origin", "url") == "https://example.com/repo.git"
    end
  end

  describe "get_all/4" do
    test "returns all values for multi-value keys" do
      text = """
      [remote "origin"]
      \tfetch = +refs/heads/*:refs/remotes/origin/*
      \tfetch = +refs/tags/*:refs/tags/*
      """

      assert {:ok, config} = Config.parse(text)
      values = Config.get_all(config, "remote", "origin", "fetch")
      assert length(values) == 2
    end
  end

  describe "set/5" do
    test "adds to existing section" do
      config =
        Config.new()
        |> Config.set("core", nil, "bare", "true")
        |> Config.set("core", nil, "filemode", "false")

      assert Config.get(config, "core", "bare") == "true"
      assert Config.get(config, "core", "filemode") == "false"
    end

    test "replaces existing key" do
      config =
        Config.new()
        |> Config.set("core", nil, "bare", "true")
        |> Config.set("core", nil, "bare", "false")

      assert Config.get(config, "core", "bare") == "false"
    end
  end

  describe "read/1 and write/2" do
    test "round-trips through filesystem" do
      path =
        Path.join(System.tmp_dir!(), "exgit_config_test_#{System.unique_integer([:positive])}")

      config =
        Config.new()
        |> Config.set("core", nil, "bare", "true")
        |> Config.set("remote", "origin", "url", "https://example.com")

      assert :ok = Config.write(config, path)
      assert {:ok, loaded} = Config.read(path)
      assert Config.get(loaded, "core", "bare") == "true"
      assert Config.get(loaded, "remote", "origin", "url") == "https://example.com"

      File.rm!(path)
    end
  end
end
