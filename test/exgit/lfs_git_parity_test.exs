defmodule Exgit.LFSGitParityTest do
  @moduledoc """
  Byte-level parity tests for `Exgit.LFS.parse/1` against real
  `git-lfs pointer --check`.

  The goal: for any given blob, exgit's "is this a valid LFS
  pointer?" answer must match git-lfs's answer. False positives
  would silently hide real content; false negatives would
  confuse agents into treating pointers as content.

  Tagged `:git_lfs` (requires the `git-lfs` binary on PATH).
  Tagged `:integration` so the default tier doesn't require the
  dependency; CI with git-lfs installed runs it explicitly.
  """
  use ExUnit.Case, async: true

  @moduletag :git_lfs
  @moduletag :integration

  alias Exgit.LFS

  setup_all do
    case System.find_executable("git-lfs") do
      nil ->
        {:skip, "git-lfs not on PATH"}

      path ->
        # Note: context key is `:git_lfs_bin`, not `:git_lfs`, to
        # avoid colliding with the `@moduletag :git_lfs` which
        # ExUnit sets as `git_lfs: true` in the test context.
        {:ok, git_lfs_bin: path, tmp: tmp_dir()}
    end
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "exgit-lfs-parity-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit_cleanup(dir)
    dir
  end

  # Schedule cleanup via ExUnit's on_exit without an alias import.
  defp on_exit_cleanup(dir) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
  end

  # Drive git-lfs's own --check on a file; returns :ok if git-lfs
  # considers the file a valid pointer, {:error, :not_pointer}
  # otherwise.
  defp git_lfs_check(git_lfs, file) do
    case System.cmd(git_lfs, ["pointer", "--check", "--file", file], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> {:error, :not_pointer}
    end
  end

  # Generate a real LFS pointer for the given content via git-lfs
  # itself, so we're matching byte-for-byte what git-lfs would
  # produce. Returns the pointer text.
  #
  # `git-lfs pointer --file=X` writes the pointer to STDOUT and
  # human-readable headers ("Git LFS pointer for ...") to STDERR.
  # We capture only stdout.
  defp gen_pointer(git_lfs, content) do
    path = Path.join(System.tmp_dir!(), "exgit-lfs-gen-#{System.unique_integer([:positive])}")
    File.write!(path, content)

    {out, 0} = System.cmd(git_lfs, ["pointer", "--file", path])
    File.rm!(path)
    out
  end

  test "accepts real git-lfs-generated pointers for various sizes",
       %{git_lfs_bin: git_lfs, tmp: tmp} do
    # Generate pointers for a range of file contents and sizes. Every
    # one must parse cleanly in exgit AND pass git-lfs's own --check.
    # Note: `git-lfs pointer --file` refuses to generate a pointer
    # for truly empty input (emits only stderr header). The unit
    # test covers zero-size pointers via handcrafted input.
    contents = [
      "a",
      "hello world\n",
      String.duplicate("x", 1024),
      # Binary content
      :crypto.strong_rand_bytes(4096)
    ]

    for {content, idx} <- Enum.with_index(contents) do
      pointer = gen_pointer(git_lfs, content)

      # exgit says yes.
      assert {:ok, info} = LFS.parse(pointer),
             "exgit rejected git-lfs-generated pointer #{idx}:\n#{pointer}"

      # git-lfs also says yes (sanity — the file we read back is the
      # same as what git-lfs just generated).
      pointer_path = Path.join(tmp, "ptr-#{idx}")
      File.write!(pointer_path, pointer)

      assert :ok = git_lfs_check(git_lfs, pointer_path),
             "git-lfs rejected its own pointer #{idx}:\n#{pointer}"

      # Size matches what git-lfs computed.
      assert info.size == byte_size(content)
    end
  end

  test "rejects non-pointer blobs that git-lfs also rejects",
       %{git_lfs_bin: git_lfs, tmp: tmp} do
    # A mix of malformed inputs. For each: exgit.parse should fail
    # AND git-lfs --check should fail. Both answers must agree.
    #
    # (Empty input is deliberately excluded — `git-lfs pointer --check
    # --file=X` returns exit 0 on empty input as a CLI quirk of "no
    # content to check," not as an assertion that empty is a valid
    # pointer. The unit test covers the empty case directly.)
    malformed = [
      {"plain text", "hello world\n"},
      {"partial", "version https://git-lfs.github.com/spec/v1\n"},
      {"wrong version url",
       "version https://example.com/v1\noid sha256:#{hex64()}\nsize 1\n"},
      {"missing oid", "version https://git-lfs.github.com/spec/v1\nsize 100\n"},
      {"keys reversed",
       "version https://git-lfs.github.com/spec/v1\nsize 100\noid sha256:#{hex64()}\n"}
    ]

    for {label, data} <- malformed do
      file = Path.join(tmp, "bad-#{:erlang.phash2(label)}")
      File.write!(file, data)

      exgit_result = LFS.parse(data)
      lfs_result = git_lfs_check(git_lfs, file)

      case {exgit_result, lfs_result} do
        {{:error, _}, {:error, _}} ->
          :ok

        other ->
          flunk("""
          Disagreement on "#{label}":
            exgit:    #{inspect(exgit_result)}
            git-lfs:  #{inspect(other)}
            data:     #{inspect(data)}
          """)
      end
    end
  end

  test "over-size blob starting with version line is rejected by both",
       %{git_lfs_bin: git_lfs, tmp: tmp} do
    # A real-world footgun: a regular blob (e.g. a README about
    # git-lfs) that happens to start with the version line but is
    # far too large to be a pointer. Neither exgit nor git-lfs
    # should accept it.
    big =
      "version https://git-lfs.github.com/spec/v1\n" <>
        String.duplicate("README about git-lfs...\n", 200)

    file = Path.join(tmp, "big-lookalike")
    File.write!(file, big)

    assert {:error, _} = LFS.parse(big)
    assert {:error, _} = git_lfs_check(git_lfs, file)
  end

  defp hex64, do: String.duplicate("a", 64)
end
