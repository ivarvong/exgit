defmodule Exgit.IndexRobustnessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.Index
  alias Exgit.Test.RealGit

  describe "index version 4 (P0.12)" do
    @tag :real_git
    test "v4 index is rejected cleanly rather than silently corrupting entries" do
      repo = RealGit.init!(RealGit.tmp_dir!())

      # Populate a few files and upgrade to version 4.
      for i <- 1..5 do
        path = Path.join(repo, "file#{i}.txt")
        File.write!(path, "content #{i}\n")
      end

      RealGit.git!(repo, ["add", "."])
      RealGit.git!(repo, ["update-index", "--index-version=4"])

      index_bytes = File.read!(Path.join(repo, ".git/index"))

      # Sanity: file starts with DIRC and version 4.
      assert <<"DIRC", 4::32, _rest::binary>> = index_bytes

      # We accept either explicit rejection (preferred) or correct parsing.
      # The one outcome we MUST reject: silent return with nonsense
      # entries for any but the first one.
      case Index.parse(index_bytes) do
        {:ok, index} ->
          # If we claim to parse v4, entries must all have readable names
          # and valid 20-byte SHAs. In the previous buggy implementation,
          # entries past the first had garbage names from prefix-compressed
          # bytes being misinterpreted.
          for entry <- index.entries do
            assert byte_size(entry.sha) == 20
            assert String.valid?(entry.name), "entry name not valid UTF-8: #{inspect(entry.name)}"

            assert String.contains?(entry.name, "file"),
                   "expected a 'file*' name, got #{inspect(entry.name)}"
          end

        {:error, {:unsupported_version, 4}} ->
          :ok

        other ->
          flunk("unexpected parse result for v4 index: #{inspect(other)}")
      end

      File.rm_rf!(repo)
    end
  end

  describe "malformed bytes do not crash (P0.13)" do
    property "Index.parse/1 never raises on arbitrary byte input" do
      check all(bytes <- binary(), max_runs: 200) do
        # Must return an {:ok, _} or {:error, _} — never raise.
        try do
          case Index.parse(bytes) do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        rescue
          e ->
            flunk(
              "Index.parse/1 raised on input=#{inspect(bytes, limit: 40)}: #{Exception.message(e)}"
            )
        end
      end
    end

    test "DIRC+version followed by garbage returns structured error" do
      garbage = "DIRC" <> <<2::32, 1::32>> <> :crypto.strong_rand_bytes(16)
      assert {:error, _} = Index.parse(garbage)
    end

    test "truncated name (no NUL terminator) returns error, not MatchError" do
      # Build a real entry header with name_len=10 but provide only 9 bytes of name.
      header =
        <<0::32, 0::32, 0::32, 0::32, 0::32, 0::32, 0o100644::32, 0::32, 0::32, 0::32>> <>
          :binary.copy(<<0>>, 20) <>
          <<10::16>>

      # 9 bytes of name, then end-of-data (no NUL terminator).
      entry_data = header <> "nineBytes"

      full = <<"DIRC", 2::32, 1::32>> <> entry_data

      assert {:error, _} = Index.parse(full)
    end
  end
end
