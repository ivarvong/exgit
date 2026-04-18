defmodule Exgit.PartialCloneIntegrationTest do
  @moduledoc """
  End-to-end tests for `Exgit.clone(url, filter: ...)` against real
  GitHub. Tagged `:integration` so they're excluded from default runs
  but run on every push to main.

  ## Why this file exists

  The reviewer's bug report:

    > When using `clone(url, filter: {:blob, :none})`, on-demand
    > blob fetches via the Promisor fail because `fetch_and_cache/2`
    > sends all cached commit SHAs as `haves`, causing the server
    > to return an empty pack (0 objects). The server deduces we
    > already have the blob because we "have" its parent commit.

  Fix: `fetch_and_cache/2` no longer sends haves. See the
  `Promisor.fetch_and_cache/2` comment for the full rationale.

  The offline test suite missed this bug because our `FilterFakeT`
  fake transport is more naive than real git servers — it returns
  whatever was asked for, regardless of haves. These tests hit
  actual `git-upload-pack` on github.com, where the bug was real.

  ## What's covered

    * `clone(url, filter: {:blob, :none})` succeeds.
    * `FS.ls` works (trees are prefetched).
    * `FS.read_path` on a file actually fetches the blob —
      this is the core bug the reporter found.
    * Multiple `read_path` calls on different files each succeed
      (regression for "empty pack after first fetch").
    * The partial-clone path survives a repo with many commits
      (the specific failure mode the reporter saw at 799 commits).
  """

  use ExUnit.Case
  @moduletag :integration
  @moduletag timeout: 120_000

  # Primary fixture. `ivarvong/pyex` is owned by the exgit
  # maintainer, so it's stable against random deletion / rename /
  # force-push. That matters for a test that asserts specific file
  # contents — we don't want to pin our regression suite to a
  # third-party repo whose owner might rewrite history one day and
  # suddenly a CI run fails for a reason that has nothing to do with
  # exgit.
  #
  # pyex has several hundred commits, which is the specific shape
  # that surfaced the reporter's bug (haves negotiation → empty pack
  # on many-commit partial clones). A smaller fixture wouldn't
  # exercise the same codepath.
  @fixture_repo "https://github.com/ivarvong/pyex"

  describe "clone(filter: {:blob, :none}) → FS.read_path" do
    test "reads a file after a partial clone" do
      assert {:ok, repo} = Exgit.clone(@fixture_repo, filter: {:blob, :none})
      assert repo.mode == :lazy

      # The file must exist AND its contents must come back
      # non-empty. Before the fix, this returned {:error, :not_found}
      # because the server shipped an empty pack in response to
      # the on-demand blob fetch.
      assert {:ok, {_mode, blob}, _repo} =
               Exgit.FS.read_path(repo, "HEAD", "README.md")

      assert is_binary(blob.data)
      assert byte_size(blob.data) > 0
    end

    test "reads multiple distinct files in one session" do
      assert {:ok, repo} = Exgit.clone(@fixture_repo, filter: {:blob, :none})

      # Regression for "first read succeeds, second returns empty
      # pack" — sanity check the on-demand fetch path is repeatable
      # across multiple distinct SHAs.
      assert {:ok, {_, readme}, repo} =
               Exgit.FS.read_path(repo, "HEAD", "README.md")

      assert {:ok, {_, license}, _repo} =
               Exgit.FS.read_path(repo, "HEAD", "LICENSE")

      assert byte_size(readme.data) > 0
      assert byte_size(license.data) > 0
      refute readme.data == license.data
    end

    test "FS.ls works on a partial clone (trees were prefetched eagerly)" do
      assert {:ok, repo} = Exgit.clone(@fixture_repo, filter: {:blob, :none})

      # ls should NOT trigger on-demand blob fetches — it only
      # needs the root tree, which was prefetched at clone time.
      assert {:ok, entries, _repo} = Exgit.FS.ls(repo, "HEAD", "")
      names = for {_mode, name, _sha} <- entries, do: name

      assert "README.md" in names
    end

    test "lazy clone (no filter) reads on-demand without sending haves" do
      # This is the lazy-only mode (refs only, no tree prefetch).
      # A read_path triggers fetches for commit → tree → blob, and
      # each of those requires the haves-less fetch to work.
      assert {:ok, repo} = Exgit.clone(@fixture_repo, lazy: true)
      assert repo.mode == :lazy

      assert {:ok, {_mode, blob}, _repo} =
               Exgit.FS.read_path(repo, "HEAD", "README.md")

      assert byte_size(blob.data) > 0
    end
  end

  describe "haves telemetry" do
    test "on-demand fetches emit haves_sent with count: 0" do
      handler_id = "haves-integration-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:exgit, :object_store, :haves_sent],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:haves_sent, measurements, metadata})
        end,
        nil
      )

      try do
        {:ok, repo} = Exgit.clone(@fixture_repo, filter: {:blob, :none})
        {:ok, _, _} = Exgit.FS.read_path(repo, "HEAD", "README.md")

        # At least one on-demand fetch happened, with zero haves.
        # Drain all haves_sent events and confirm every on-demand
        # fetch sent 0 haves.
        drain_haves_and_assert_zero()
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  # Drain queued telemetry messages and assert that every on-demand
  # fetch reported 0 haves. Asserts at least one message was seen.
  defp drain_haves_and_assert_zero(seen \\ 0) do
    receive do
      {:haves_sent, %{count: count}, %{context: :on_demand_fetch}} ->
        assert count == 0,
               "expected on_demand_fetch to send 0 haves, got #{count}"

        drain_haves_and_assert_zero(seen + 1)

      {:haves_sent, _, _} ->
        # Not an on-demand fetch (e.g. bulk fetch). Skip.
        drain_haves_and_assert_zero(seen)
    after
      200 ->
        assert seen > 0,
               "no [:exgit, :object_store, :haves_sent] telemetry with context: :on_demand_fetch received"
    end
  end
end
