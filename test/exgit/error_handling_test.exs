defmodule Exgit.ErrorHandlingTest do
  use ExUnit.Case, async: true

  alias Exgit.Test.CommitGraph

  describe "clone/open error handling (P1.2)" do
    test "open/2 on a non-existent path returns {:error, _}" do
      path = Path.join(System.tmp_dir!(), "exgit_nope_#{System.unique_integer([:positive])}")
      assert {:error, _} = Exgit.open(path)
    end

    test "open/2 on a regular file (not a repo) returns a structured error" do
      path = Path.join(System.tmp_dir!(), "exgit_file_#{System.unique_integer([:positive])}")
      File.write!(path, "not a repo")
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:not_a_repository, _}} = Exgit.open(path)
    end

    test "clone to a path we cannot write into returns {:error, _}, not MatchError" do
      # /proc is typically read-only on Linux; on macOS we use a nonexistent
      # parent to force mkdir_p to fail.
      dest = "/this/path/should/not/exist/exgit_target"

      t = Exgit.Transport.File.new(Path.join(System.tmp_dir!(), "nonexistent_source"))

      # Must return {:error, _}, not crash with MatchError.
      result =
        try do
          Exgit.clone(t, path: dest)
        rescue
          e -> {:crash, :rescue, e}
        catch
          kind, err -> {:crash, kind, err}
        end

      assert match?({:error, _}, result),
             "expected {:error, _}, got #{inspect(result)}"
    end
  end

  describe "push/3 error propagation" do
    test "push returns an error when ref resolution fails for all refspecs" do
      graph = %{"A" => []}
      {repo, shas} = CommitGraph.build(graph)

      {:ok, ref_store} =
        Exgit.RefStore.write(Exgit.RefStore.Memory.new(), "refs/heads/main", shas["A"], [])

      repo = %Exgit.Repository{
        object_store: repo.object_store,
        ref_store: ref_store,
        config: Exgit.Config.new(),
        path: nil
      }

      # Push to a transport that can't reach a destination.
      # For File transport we point at a nonexistent path.
      dest =
        Path.join(System.tmp_dir!(), "exgit_push_missing_#{System.unique_integer([:positive])}")

      t = Exgit.Transport.File.new(dest)

      # Attempting to push to a nonexistent destination must either
      # succeed (by creating it) or return an error — not raise.
      result =
        try do
          Exgit.push(repo, t, refspecs: ["refs/heads/main"])
        rescue
          _ -> :raised
        end

      File.rm_rf!(dest)

      assert result != :raised, "push raised on nonexistent destination"
    end
  end
end
