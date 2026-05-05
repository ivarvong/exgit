defmodule Exgit.BootWithVfsTest do
  @moduledoc """
  Regression: starting `:exgit` and `:vfs` in the same VM must not
  deadlock `:application_controller`.

  History: a prior revision declared `{:vfs, optional: true}` without
  `runtime: false`. Mix then auto-injected `:vfs` into exgit's generated
  `applications` list. Because vfs (in dev/test) depends on exgit, any
  build that bundled both libs created a cycle in
  `:application_controller` that wedged at boot:

      exgit -> :application_controller starts :vfs
              -> :vfs's deps include exgit
              -> :application_controller deadlocks waiting on itself

  `optional_applications` only tells the controller "it's OK if this
  app is absent" — it does not remove the dependency edge when the app
  is loaded. The fix is `runtime: false` on the :vfs entry: it tells
  Mix "compile against this, but don't list it in applications."

  This test exercises the actual failure mode: ensure both apps can
  start in the same VM. If a future change reintroduces the cycle,
  this test deadlocks (caught by ExUnit's per-test timeout).
  """

  use ExUnit.Case, async: false

  @moduletag :smoke
  # Per-test timeout shorter than ExUnit's default 60s so a regression
  # surfaces as a clear failure, not a stuck CI run.
  @moduletag timeout: 30_000

  test "exgit and vfs boot together without deadlocking application_controller" do
    # Sanity: vfs must be loadable in this build. The 1.17 CI tier
    # skips :vfs entirely; if so, the regression we're guarding against
    # cannot manifest, so just pass.
    if Code.ensure_loaded?(VFS.Mountable) do
      # Start order doesn't matter for the bug — the deadlock came from
      # exgit's `applications` list referencing :vfs, so starting :exgit
      # alone was enough to wedge. Start exgit first to mirror the
      # reproducer in the upstream report.
      assert {:ok, _started} = Application.ensure_all_started(:exgit)
      assert {:ok, _started} = Application.ensure_all_started(:vfs)

      # Both must actually be running, not just "loaded".
      running = Application.started_applications() |> Enum.map(&elem(&1, 0))
      assert :exgit in running
      assert :vfs in running
    else
      :ok
    end
  end
end
