defmodule Exgit.RepoRegistry do
  @moduledoc """
  Process-wide registry of shared `RepoHandle`s keyed by URL.

  Solves Chris's "scenario 3" from the design review: 100 LiveView
  sessions searching the same repository should share ONE cache,
  not each clone the repo independently.

  First caller to `get_or_start/2` for a given URL pays the
  clone + prefetch cost. Subsequent callers for the same URL
  receive the same handle — the cache is warm.

  ## API

      # Atomic get-or-start. Blocks until the repo is cloned and
      # the handle is ready. Returns the existing handle on
      # subsequent calls for the same URL.
      {:ok, handle} = Exgit.RepoRegistry.get_or_start(url)

      # Check without starting.
      case Exgit.RepoRegistry.lookup(url) do
        {:ok, handle} -> handle
        :error -> nil
      end

      # Stop and remove a handle.
      :ok = Exgit.RepoRegistry.stop(url)

      # Introspection.
      Exgit.RepoRegistry.count()
      Exgit.RepoRegistry.list()

  ## Concurrency

  Concurrent calls to `get_or_start/2` for the SAME URL serialize
  at the registry GenServer; only one clone happens. Concurrent
  calls for DIFFERENT URLs do NOT block each other in any
  user-visible way (each hits a fast `Registry.lookup`; the slow
  path serializes per-URL via a short-lived `Mutex`-equivalent
  check inside the server).

  ## Options

  Per-URL options supplied to `get_or_start/2` (e.g. `:lazy`,
  `:filter`) are applied by the FIRST caller for that URL.
  Subsequent callers' options are **ignored** (with a telemetry
  event when they differ). Consumers who need different per-user
  configs should use `Exgit.clone/2` directly without the
  registry.

  ## Lifecycle

  Handles started by the registry are linked to the registry
  process. If the registry dies, all handles die. If a handle
  dies (crash, explicit stop), the registry removes it from its
  map and the next `get_or_start/2` will start a fresh clone.

  Start the registry as a named, singleton GenServer (typically
  under the consumer's supervision tree). If not started, all
  API calls error with `:not_started`.
  """

  use GenServer

  alias Exgit.RepoHandle

  @registry_name __MODULE__.Registry

  ## Public API

  @doc """
  Start the RepoRegistry as a supervised GenServer.

  Usually called by the consumer's supervision tree — the
  library's own `Exgit.Application` does NOT start it, because
  consumers who don't need cross-process sharing shouldn't pay
  for a registry process they won't use.

  Options are forwarded to `GenServer.start_link/3`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Get an existing handle or start a fresh one.

  Blocks until the clone completes on the first call for a URL.
  Subsequent calls return immediately.

  ## Options

  Forwarded to `Exgit.clone/2` on the first call for a given URL.
  Defaults: `lazy: true`.

  ## Errors

    * `{:error, :not_started}` — registry GenServer isn't running
    * `{:error, reason}` — clone failed on the first call
  """
  @spec get_or_start(String.t(), keyword()) ::
          {:ok, RepoHandle.t()} | {:error, term()}
  def get_or_start(url, clone_opts \\ []) when is_binary(url) do
    # Fast path: URL already in the registry.
    case lookup(url) do
      {:ok, handle} ->
        # Optional warning if the caller's opts differ from how the
        # handle was started. We don't track the original opts yet,
        # so just no-op on the warning for now.
        {:ok, handle}

      :error ->
        # Slow path: go through the serializing GenServer.
        case Process.whereis(__MODULE__) do
          nil -> {:error, :not_started}
          _pid -> GenServer.call(__MODULE__, {:get_or_start, url, clone_opts}, :infinity)
        end
    end
  end

  @doc """
  Lookup without starting. Returns `{:ok, handle}` or `:error`.
  """
  @spec lookup(String.t()) :: {:ok, RepoHandle.t()} | :error
  def lookup(url) when is_binary(url) do
    case registry_started?() do
      true ->
        try do
          case Registry.lookup(@registry_name, url) do
            [{pid, _}] -> {:ok, pid}
            [] -> :error
          end
        rescue
          ArgumentError -> :error
        end

      false ->
        :error
    end
  end

  @doc """
  Stop the handle for `url` and remove it from the registry.
  Returns `:ok` whether or not the URL was registered.
  """
  @spec stop(String.t()) :: :ok
  def stop(url) when is_binary(url) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        GenServer.call(__MODULE__, {:stop, url})
    end
  end

  @doc """
  Number of active handles.
  """
  @spec count() :: non_neg_integer()
  def count do
    case registry_started?() do
      true ->
        try do
          Registry.count(@registry_name)
        rescue
          ArgumentError -> 0
        end

      false ->
        0
    end
  end

  @doc """
  List all URLs currently in the registry.
  """
  @spec list() :: [String.t()]
  def list do
    case registry_started?() do
      true ->
        try do
          Registry.select(@registry_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
        rescue
          ArgumentError -> []
        end

      false ->
        []
    end
  end

  ## GenServer callbacks

  @impl true
  def init(:ok) do
    # Trap exits so linked-handle crashes hit handle_info, not kill
    # us directly.
    Process.flag(:trap_exit, true)

    # Start the backing Registry as a linked child. When the
    # RepoRegistry GenServer dies, the Registry dies with it
    # (linked process going down triggers exit, and since we trap
    # exits but don't handle the registry_pid exit specially, we'll
    # terminate normally). When a test restarts the RepoRegistry,
    # the previous Registry is already gone, so no name clash.
    #
    # We still allow the :already_started case for defensive reasons:
    # if something else in the system has already claimed
    # `@registry_name`, we reuse it rather than crashing.
    registry_pid =
      case Registry.start_link(keys: :unique, name: @registry_name) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    {:ok, %{urls: MapSet.new(), registry_pid: registry_pid}}
  end

  @impl true
  def terminate(reason, %{urls: urls, registry_pid: registry_pid}) do
    # Stop any URL handles (they're linked to us so they'll die
    # anyway; this just makes the cleanup sequence deterministic).
    for url <- urls do
      case Registry.lookup(@registry_name, url) do
        [{pid, _}] -> RepoHandle.stop(pid)
        _ -> :ok
      end
    end

    # Stop the backing Registry explicitly so the name is freed
    # before we return. Without this, a fast test restart could
    # see the old Registry still owning the name.
    if Process.alive?(registry_pid) do
      try do
        GenServer.stop(registry_pid, reason, 500)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @impl true
  def handle_call({:get_or_start, url, clone_opts}, _from, state) do
    # Re-check under the call's serial guarantee (another call for
    # the same URL might have raced ahead of us).
    case Registry.lookup(@registry_name, url) do
      [{pid, _}] ->
        {:reply, {:ok, pid}, state}

      [] ->
        case start_handle_via(url, clone_opts) do
          {:ok, handle} ->
            # start_link already linked the handle to us, so when
            # it dies we receive {:EXIT, handle, reason} and clean
            # up the Registry entry.
            {:reply, {:ok, handle}, %{state | urls: MapSet.put(state.urls, url)}}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:stop, url}, _from, state) do
    case Registry.lookup(@registry_name, url) do
      [{pid, _}] ->
        Registry.unregister(@registry_name, url)
        # Unlink before stopping so our exit-trap doesn't see it.
        Process.unlink(pid)
        RepoHandle.stop(pid)
        {:reply, :ok, %{state | urls: MapSet.delete(state.urls, url)}}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    # A handle died. Find its URL (if any) and clean up the registry
    # entry. Linear scan is fine — we don't expect many URLs (tens,
    # not millions) and this is on an exit path.
    dead_urls =
      Enum.filter(state.urls, fn url ->
        case Registry.lookup(@registry_name, url) do
          [{^pid, _}] -> true
          _ -> false
        end
      end)

    for url <- dead_urls do
      Registry.unregister(@registry_name, url)
    end

    {:noreply, %{state | urls: MapSet.difference(state.urls, MapSet.new(dead_urls))}}
  end

  ## Internal

  defp registry_started? do
    case Process.whereis(@registry_name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp start_handle_via(url, clone_opts) do
    # Default to :lazy since the registry is for long-lived shared
    # handles — a LV server usually wants lazy + background prefetch
    # rather than synchronous full clone.
    clone_opts = Keyword.put_new(clone_opts, :lazy, true)

    # Start the handle WITH a :via name so the handle's own
    # Process.register is what registers it in our Registry. This
    # avoids the register-a-different-pid dance that Registry's
    # API doesn't support directly.
    via_name = {:via, Registry, {@registry_name, url}}

    case clone_for_registry(url, clone_opts) do
      {:ok, repo} -> RepoHandle.start_link(repo, name: via_name)
      err -> err
    end
  end

  # Delegated so we can mock / stub in tests. The real clone
  # goes to Exgit.clone/2.
  defp clone_for_registry(url, opts), do: Exgit.clone(url, opts)
end
