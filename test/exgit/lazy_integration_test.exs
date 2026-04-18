defmodule Exgit.LazyIntegrationTest do
  @moduledoc """
  End-to-end lazy-clone test against a live git server. Tagged
  `:integration` so it's excluded from default runs.
  """
  use ExUnit.Case
  @moduletag :integration

  @repo_url "https://github.com/elixir-ai-tools/just_bash"

  test "lazy clone against real GitHub fetches only what FS.read_path touches" do
    assert {:ok, repo} = Exgit.clone(@repo_url, lazy: true)
    assert repo.mode == :lazy

    # Read a couple of files. Each read triggers an on-demand fetch.
    # Thread the updated repo forward so subsequent reads benefit from
    # the populated cache.
    assert {:ok, {_mode, readme}, repo} = Exgit.FS.read_path(repo, "HEAD", "README.md")
    assert is_binary(readme.data)

    assert {:ok, {_mode, mix}, repo} = Exgit.FS.read_path(repo, "HEAD", "mix.exs")
    assert mix.data =~ "JustBash"

    # ls at root uses the same cache.
    assert {:ok, entries, _repo} = Exgit.FS.ls(repo, "HEAD", "")
    names = for {_m, n, _s} <- entries, do: n
    assert "README.md" in names
    assert "mix.exs" in names
  end
end
