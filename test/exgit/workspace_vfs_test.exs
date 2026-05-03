if Code.ensure_loaded?(VFS.Mountable) and Code.ensure_loaded?(VFS.ConformanceCase) do
  defmodule Exgit.WorkspaceVFSTest do
    @moduledoc """
    `VFS.Mountable` conformance for `Exgit.Workspace`.

    Runs the standard vfs backend test set against a workspace built
    from an in-memory `Exgit.Repository`. Excluded from the 1.17 CI
    tier (where `:vfs` doesn't resolve) via the file-level guard.
    """

    use VFS.ConformanceCase,
      backend: &Exgit.Test.WorkspaceVFSFixture.fresh/0,
      capabilities: [:read, :write, :lazy]

    @moduletag :vfs
  end
end
