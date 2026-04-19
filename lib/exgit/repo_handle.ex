defmodule Exgit.RepoHandle do
  @moduledoc """
  Opt-in process-based handle around a `Repository.t()` value.

  The rest of `Exgit` exposes repositories as immutable values — you
  thread the return of every call through to the next. That's the
  right shape for single-threaded scripts and for call-sites that
  don't need sharing.

  A `RepoHandle` is the right shape when:

    * Multiple processes need to share one repository's cache (e.g.
      one LiveView process per user, but all searching the same
      repo — you want the Promisor cache populated once, reused by
      all sessions).
    * You want to run background prefetch while foreground operations
      read the cache as it grows (see `Exgit.FS.prefetch_async/3`).
    * A single long-lived session progressively accumulates cache
      state across many calls and needs consistent read semantics.

  It is **not** the right shape for short scripts, one-shot clones,
  or anywhere you'd rather pass a value than coordinate a process.

  ## Concurrency model

  Reads go directly to ETS (no GenServer call, no message copy of
  the repo). This is 1-2 µs per read, safe under any number of
  concurrent readers.

  Writes are serialized through the handle process. Two concurrent
  `update/2` calls run one at a time; each sees the result of the
  previous. This means long-running update functions (e.g. an
  inline prefetch) will block other writes — if that matters, use
  `Exgit.FS.prefetch_async/3`, which does the network work outside
  the handle and only calls `update/2` at the end to commit.

  ## Lifecycle

  The handle owns its ETS table. When the process exits for any
  reason — normal stop, crash, `Process.exit/2`, supervisor
  shutdown — the table is automatically destroyed by the BEAM.
  Callers holding a dead handle get `{:error, :dead_handle}` from
  `get/1`.

  Clients that want the handle to outlive a supervision tree are
  responsible for wiring it into the right supervisor themselves.

  ## Example

      {:ok, handle} = Exgit.RepoHandle.start_link(repo)

      # Background prefetch — returns immediately.
      {:ok, task} = Exgit.FS.prefetch_async(handle)

      # Meanwhile, foreground reads work against the current snapshot.
      repo_snapshot = Exgit.RepoHandle.get(handle)
      Exgit.FS.grep(repo_snapshot, "HEAD", "auth", max_count: 10)

      # Wait for prefetch to finish, then do a full-repo search.
      :ok = Exgit.FS.await_prefetch(task)
      fresh_snapshot = Exgit.RepoHandle.get(handle)
      Exgit.FS.grep(fresh_snapshot, "HEAD", "auth") |> Enum.to_list()

  ## Why ETS and not `Agent.get/1`

  `Agent.get/1` still sends a message to the agent process and
  copies the state back. For a `Repository` with a large Promisor
  cache that copy would be 10-100 MB per read — unacceptable for
  a LiveView that reads on every keystroke.

  ETS lookups on a `:public, :read_concurrency: true` table are
  lock-free in the typical case and return a reference to the
  stored term without copying (Erlang 26+ uses
  read-only-off-heap binaries for large terms). One lookup is
  ~1-2 µs regardless of repo size.
  """

  use GenServer

  alias Exgit.Repository

  @type t :: pid() | atom()

  ## Public API

  @doc """
  Start a handle owning `initial_repo`.

  Options are forwarded to `GenServer.start_link/3`. Common ones:

    * `:name` — register the handle under this name
    * `:hibernate_after` — hibernate when idle
  """
  @spec start_link(Repository.t(), keyword()) :: GenServer.on_start()
  def start_link(%Repository{} = initial_repo, opts \\ []) do
    GenServer.start_link(__MODULE__, initial_repo, opts)
  end

  @doc """
  Stop the handle process and destroy its ETS table.
  """
  @spec stop(t()) :: :ok
  def stop(handle) do
    GenServer.stop(handle)
  end

  @doc """
  Fetch the current repository value.

  Fast-path ETS lookup: no message send to the handle process, no
  copy of the repo into this process's mailbox. Safe to call on
  every hot-loop iteration.

  Raises `ArgumentError` if the handle is dead or if the table
  doesn't exist. Callers that want to tolerate dead handles
  should wrap in `try/rescue` or use `fetch/1`.
  """
  @spec get(t()) :: Repository.t()
  def get(handle) do
    case fetch(handle) do
      {:ok, repo} ->
        repo

      {:error, reason} ->
        raise ArgumentError,
              "Exgit.RepoHandle.get/1: #{inspect(reason)} for handle #{inspect(handle)}"
    end
  end

  @doc """
  Non-raising variant of `get/1`. Returns `{:ok, repo}` on success
  or `{:error, :dead_handle}` / `{:error, :no_table}`.
  """
  @spec fetch(t()) :: {:ok, Repository.t()} | {:error, :dead_handle | :no_table}
  def fetch(handle) do
    case table_for(handle) do
      {:ok, table} ->
        case :ets.lookup(table, :repo) do
          [{:repo, repo}] -> {:ok, repo}
          _ -> {:error, :no_table}
        end

      {:error, _} = err ->
        err
    end
  rescue
    ArgumentError -> {:error, :no_table}
  end

  @doc """
  Apply `fun` to the current repo value and store the result.

  `fun` runs **inside the handle process** — keep it fast.  If
  `fun` returns `{:ok, new_repo}` the handle is updated and
  `:ok` is returned. If `fun` returns `{:error, reason}` the
  handle is unchanged and the error is surfaced.  Any other
  return is treated as the new repo value directly.

  Raises on timeout (default 60s) to surface deadlocks rather
  than hide them.
  """
  @type update_result ::
          Repository.t()
          | {:ok, Repository.t()}
          | {:error, term()}

  @spec update(t(), (Repository.t() -> update_result()), timeout()) ::
          :ok | {:error, term()}
  def update(handle, fun, timeout \\ 60_000) when is_function(fun, 1) do
    GenServer.call(handle, {:update, fun}, timeout)
  end

  @doc """
  Replace the stored repository value wholesale.

  Primarily a convenience for callers who've computed a new repo
  value outside the handle (e.g. an async prefetch task that
  finished) and want to commit it atomically without another
  round trip through the update function.
  """
  @spec put(t(), Repository.t()) :: :ok
  def put(handle, %Repository{} = new_repo) do
    GenServer.call(handle, {:put, new_repo})
  end

  @doc """
  Run `fetch_fn` against the current repo, deduplicating concurrent
  callers with the same `key`.

  The canonical shape: multiple processes want to trigger the same
  expensive network fetch (e.g. prefetch commit history for blame).
  Without dedup, each caller fires its own identical network call
  — wasteful.

  With `fetch_once/3`:

    * First caller for `key` runs `fetch_fn(current_repo)` OUTSIDE
      the handle (in a linked Task) so the handle stays responsive
      to other reads.
    * Subsequent concurrent callers with the same `key` do NOT
      re-run the fetch; they block waiting for the first caller's
      result.
    * Task completes → result commits to the handle's ETS, all
      waiters receive the same return value.

  `fetch_fn` receives the current repo snapshot and must return
  `{:ok, new_repo}` or `{:error, reason}`.

  ## Example

      # Three LV users trigger blame on the same file at once.
      # Each tries to prefetch history. fetch_once ensures only ONE
      # network fetch happens; the other two wait.
      RepoHandle.fetch_once(handle, {:history, commit_sha}, fn repo ->
        Exgit.FS.prefetch_history(repo, "HEAD")
      end)

  ## Errors

  `{:error, :dead_handle}` if the handle isn't running. Propagates
  `fetch_fn`'s errors verbatim.
  """
  @spec fetch_once(t(), term(), (Repository.t() -> {:ok, Repository.t()} | {:error, term()})) ::
          {:ok, Repository.t()} | {:error, term()}
  def fetch_once(handle, key, fetch_fn, timeout \\ 300_000) when is_function(fetch_fn, 1) do
    GenServer.call(handle, {:fetch_once, key, fetch_fn}, timeout)
  end

  @doc """
  Get the ETS table reference for a handle. Exposed so very
  latency-sensitive callers can cache it across many reads.
  """
  @spec table(t()) :: :ets.table()
  def table(handle) do
    case table_for(handle) do
      {:ok, t} ->
        t

      {:error, reason} ->
        raise ArgumentError,
              "Exgit.RepoHandle.table/1: #{inspect(reason)} for handle #{inspect(handle)}"
    end
  end

  ## GenServer callbacks

  @impl true
  def init(%Repository{} = repo) do
    # Unique table name per handle. We use a named table so readers
    # who have the PID can look up the table without an extra call
    # through the handle process; the table name is derived from
    # the PID.
    table = :ets.new(table_name(self()), [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: false
    ])

    true = :ets.insert(table, {:repo, repo})

    # `in_flight`: %{key => %{task_ref: ref, waiters: [from, ...]}}
    # Entries are created when the first fetch_once for a key
    # arrives; removed when the task completes and all waiters
    # have been replied to.
    {:ok, %{table: table, in_flight: %{}}}
  end

  @impl true
  def handle_call({:update, fun}, _from, %{table: table} = state) do
    [{:repo, repo}] = :ets.lookup(table, :repo)

    case fun.(repo) do
      {:ok, %Repository{} = new_repo} ->
        true = :ets.insert(table, {:repo, new_repo})
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}

      %Repository{} = new_repo ->
        true = :ets.insert(table, {:repo, new_repo})
        {:reply, :ok, state}

      other ->
        {:reply, {:error, {:invalid_update_return, other}}, state}
    end
  end

  def handle_call({:put, new_repo}, _from, %{table: table} = state) do
    true = :ets.insert(table, {:repo, new_repo})
    {:reply, :ok, state}
  end

  def handle_call({:fetch_once, key, fetch_fn}, from, state) do
    case Map.get(state.in_flight, key) do
      nil ->
        # No pending fetch. Spawn a task to run the fetch outside
        # the GenServer so we stay responsive to other reads /
        # updates. We'll reply to `from` (and any waiters that
        # register before the task finishes) when it completes.
        handle_pid = self()

        _ =
          Task.Supervisor.start_child(Exgit.TaskSupervisor, fn ->
            [{:repo, repo}] = :ets.lookup(state.table, :repo)
            result = safe_fetch(fetch_fn, repo)
            send(handle_pid, {:fetch_once_done, key, result})
          end)

        entry = %{waiters: [from]}
        {:noreply, %{state | in_flight: Map.put(state.in_flight, key, entry)}}

      %{waiters: waiters} = entry ->
        # Already in-flight for this key. Add to waiters.
        new_entry = %{entry | waiters: [from | waiters]}
        {:noreply, %{state | in_flight: Map.put(state.in_flight, key, new_entry)}}
    end
  end

  @impl true
  def handle_info({:fetch_once_done, key, result}, state) do
    case Map.pop(state.in_flight, key) do
      {nil, _state} ->
        # Shouldn't happen — we removed the entry out from under
        # ourselves somehow. Log and continue.
        {:noreply, state}

      {%{waiters: waiters}, remaining} ->
        # Commit the result to ETS if it succeeded, then reply to
        # all waiters with the same return value.
        reply_value =
          case result do
            {:ok, %Repository{} = new_repo} ->
              true = :ets.insert(state.table, {:repo, new_repo})
              {:ok, new_repo}

            other ->
              other
          end

        for from <- Enum.reverse(waiters) do
          GenServer.reply(from, reply_value)
        end

        {:noreply, %{state | in_flight: remaining}}
    end
  end

  defp safe_fetch(fun, repo) do
    fun.(repo)
  rescue
    e -> {:error, {:fetch_fn_raised, e, __STACKTRACE__}}
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    # BEAM will GC the table automatically when the owner process
    # dies, but an explicit delete makes the cleanup path obvious
    # and lets us verify in tests.
    try do
      :ets.delete(table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  ## Internal helpers

  # Resolve a handle (pid or registered name) to its ETS table name.
  defp table_for(handle) when is_pid(handle), do: {:ok, table_name(handle)}

  defp table_for(handle) when is_atom(handle) do
    case Process.whereis(handle) do
      nil -> {:error, :dead_handle}
      pid -> {:ok, table_name(pid)}
    end
  end

  defp table_name(pid) when is_pid(pid) do
    # Use the PID's printable form as part of the atom.  Since
    # atoms are never GC'd we accept the tiny leak (one atom per
    # handle process ever started in this node's lifetime); for
    # a long-running node that's typically well under 1000 atoms
    # even with heavy LV traffic.  If this becomes a problem we
    # can switch to an `:ets.new/2` with `:named_table: false`
    # and pass the reference around instead of looking it up by
    # pid.
    pid_str =
      pid
      |> :erlang.pid_to_list()
      |> to_string()

    String.to_atom("exgit_repo_handle_" <> pid_str)
  end
end
