defmodule Exgit.Application do
  @moduledoc """
  OTP application callback for Exgit.

  Starts a minimal supervision tree that only exists to support
  opt-in process-based features:

    * `Exgit.TaskSupervisor` — `Task.Supervisor` used by
      `Exgit.FS.prefetch_async/2` to run background prefetches
      under supervision. The supervisor uses
      `restart: :temporary` semantics by default (Task.Supervisor
      never restarts a dead task), so a crashed prefetch is
      logged and forgotten, not infinitely retried.

  Callers who use only the pure-value API (`Exgit.clone/2`,
  `Exgit.FS.grep/4`, etc.) pay for this supervisor but its cost
  is negligible: one idle Erlang process (<1 KB). If even that is
  unacceptable, build with `otp_app: false` — but then
  `Exgit.RepoHandle`, `Exgit.FS.prefetch_async/2`, and
  `Exgit.RepoRegistry` will not be available.

  The `Exgit.IndexCache` ETS owner is also started here for the
  pre-existing idx view cache.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Named Task.Supervisor for async prefetch tasks. Name is
      # module-global so the FS.prefetch_async/2 API can find it
      # without each caller threading a supervisor ref.
      {Task.Supervisor, name: Exgit.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Exgit.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
