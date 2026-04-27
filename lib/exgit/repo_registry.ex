defmodule Exgit.RepoRegistry do
  @moduledoc """
  Process-wide registry of shared `RepoHandle`s keyed by URL and credential.

  Solves the "many sessions, one repo" problem: 100 LiveView sessions
  searching the same repository should share ONE cache, not each clone
  independently. First caller to `get_or_start/2` for a given URL pays
  the clone + prefetch cost; subsequent callers for the same URL and
  the same credential receive the same warm handle.

  ## Credential scoping

  The registry key is `{url, credential_hash}`, not just `url`.

  Two callers with **different credentials** for the same URL get
  **separate handles**. This is a security boundary: a low-privilege
  token must not share a cache with a high-privilege token that can
  read private branches. The credential hash is a SHA-256 of the
  credential's auth value; the plaintext credential is never stored
  in the registry state.

  Two callers with **identical credentials** (or both with no
  credentials) share one handle.

  Public repos are typically accessed without a token. If you pass
  a PAT for a public repo, you violate the invariant documented in
  CLAUDE.md; this registry won't stop you, but the credential hash
  will create an unnecessary second handle.

  ## Concurrency

  `get_or_start/2` serializes through the GenServer only on a cache
  miss. Cache hits are served by a direct Registry lookup — no
  message send to the GenServer.

  ## State design

  The registry maintains two maps for O(1) operations in all paths:

    * `handles: %{{url, cred_hash} => pid}` — forward lookup
    * `pids:    %{pid => {url, cred_hash}}` — reverse map for exit handler

  When a handle exits, `handle_info({:EXIT, pid, _reason})` removes
  the entry in O(1) via `pids`, with no scan over all URLs.

  ## Known structural issue

  The backing `Registry` is started as a linked peer inside `init/1`
  rather than as a sibling under a shared supervisor. This works
  because:

    1. The Registry is linked to the GenServer, so it dies when the
       GenServer dies (correct cleanup behaviour).
    2. `terminate/2` explicitly stops the Registry so the name is
       freed before a fast test restart can claim it.

  The idiomatic OTP structure would be a `Supervisor` child spec
  starting both the Registry and the GenServer together. That would
  eliminate the `terminate/2` cleanup ceremony. Left as a follow-up;
  the current behaviour is correct for the single-node production
  case and tests pass reliably.

  ## API

      # Atomic get-or-start.
      {:ok, handle} = Exgit.RepoRegistry.get_or_start(url)
      {:ok, handle} = Exgit.RepoRegistry.get_or_start(url, auth: token)

      # Check without starting.
      {:ok, handle} | :error = Exgit.RepoRegistry.lookup(url)
      {:ok, handle} | :error = Exgit.RepoRegistry.lookup(url, auth: token)

      # Stop a handle.
      :ok = Exgit.RepoRegistry.stop(url)
      :ok = Exgit.RepoRegistry.stop(url, auth: token)

      # Introspection.
      Exgit.RepoRegistry.count()
      Exgit.RepoRegistry.list()
  """

  use GenServer

  alias Exgit.RepoHandle

  @registry_name __MODULE__.Registry

  ## Public API

  @doc """
  Start the RepoRegistry as a supervised GenServer.

  The library's own `Exgit.Application` does NOT start it — callers
  who don't need cross-process sharing shouldn't pay for a registry
  they won't use. Add it to your own supervision tree.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Get an existing handle or start a fresh one.

  Blocks until the clone completes on the first call for a given
  `{url, auth}` combination. Subsequent calls return immediately.

  ## Options

  * `:auth` — credential (passed to `Exgit.clone/2` on first call).
    Two callers with the same `:auth` value share one handle; callers
    with different values get isolated handles.
  * All other options are forwarded to `Exgit.clone/2` on the first
    call. Options from subsequent callers for the same key are ignored.

  ## Errors

    * `{:error, :not_started}` — registry GenServer isn't running
    * `{:error, reason}` — clone failed
  """
  @spec get_or_start(String.t(), keyword()) ::
          {:ok, RepoHandle.t()} | {:error, term()}
  def get_or_start(url, clone_opts \\ []) when is_binary(url) do
    key = registry_key(url, clone_opts)

    # Fast path: already registered.
    case lookup_by_key(key) do
      {:ok, handle} ->
        {:ok, handle}

      :error ->
        case Process.whereis(__MODULE__) do
          nil -> {:error, :not_started}
          _pid -> GenServer.call(__MODULE__, {:get_or_start, key, url, clone_opts}, :infinity)
        end
    end
  end

  @doc """
  Lookup without starting. Pass the same `:auth` option you would
  pass to `get_or_start/2` to find the right scoped handle.
  """
  @spec lookup(String.t(), keyword()) :: {:ok, RepoHandle.t()} | :error
  def lookup(url, opts \\ []) when is_binary(url) do
    lookup_by_key(registry_key(url, opts))
  end

  @doc """
  Stop the handle for `{url, auth}` and remove it from the registry.
  """
  @spec stop(String.t(), keyword()) :: :ok
  def stop(url, opts \\ []) when is_binary(url) do
    key = registry_key(url, opts)

    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:stop, key})
    end
  end

  @doc "Number of active handles."
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

  @doc "List all `{url, credential_hash}` keys currently in the registry."
  @spec list() :: [{String.t(), String.t()}]
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
    Process.flag(:trap_exit, true)

    registry_pid =
      case Registry.start_link(keys: :unique, name: @registry_name) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    # Two maps for O(1) operations in all directions.
    # `handles`: {url, cred_hash} → pid   (forward lookup)
    # `pids`:    pid → {url, cred_hash}   (reverse, for O(1) exit cleanup)
    {:ok, %{handles: %{}, pids: %{}, registry_pid: registry_pid}}
  end

  @impl true
  def terminate(reason, %{handles: handles, registry_pid: registry_pid}) do
    for {_key, pid} <- handles do
      if Process.alive?(pid) do
        Process.unlink(pid)
        RepoHandle.stop(pid)
      end
    end

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
  def handle_call({:get_or_start, key, url, clone_opts}, _from, state) do
    # Re-check under the serializing call in case a concurrent call
    # already started the handle while we were in the mailbox queue.
    case lookup_by_key(key) do
      {:ok, pid} ->
        {:reply, {:ok, pid}, state}

      :error ->
        case start_handle(key, url, clone_opts) do
          {:ok, handle} ->
            state = %{
              state
              | handles: Map.put(state.handles, key, handle),
                pids: Map.put(state.pids, handle, key)
            }

            {:reply, {:ok, handle}, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:stop, key}, _from, state) do
    case Map.pop(state.handles, key) do
      {nil, _} ->
        {:reply, :ok, state}

      {pid, handles} ->
        Registry.unregister(@registry_name, key)
        Process.unlink(pid)
        RepoHandle.stop(pid)
        pids = Map.delete(state.pids, pid)
        {:reply, :ok, %{state | handles: handles, pids: pids}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    # O(1): reverse map gives us the key directly.
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        {:noreply, state}

      {key, pids} ->
        Registry.unregister(@registry_name, key)
        handles = Map.delete(state.handles, key)
        {:noreply, %{state | handles: handles, pids: pids}}
    end
  end

  ## Internal

  # The registry key pairs the URL with a hash of the credential so
  # that different credentials for the same URL get isolated handles.
  # The hash is a truncated SHA-256; we never store the plaintext
  # credential in registry state.
  defp registry_key(url, opts) do
    auth = Keyword.get(opts, :auth)
    {url, credential_hash(auth)}
  end

  defp credential_hash(nil), do: "anonymous"

  defp credential_hash(%Exgit.Credentials{auth: auth}), do: credential_hash(auth)

  defp credential_hash({:basic, user, pass}) do
    :crypto.hash(:sha256, "basic:#{user}:#{pass}")
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp credential_hash({:bearer, token}) do
    :crypto.hash(:sha256, "bearer:#{token}")
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp credential_hash(other) do
    :crypto.hash(:sha256, :erlang.term_to_binary(other))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp lookup_by_key(key) do
    case registry_started?() do
      true ->
        try do
          case Registry.lookup(@registry_name, key) do
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

  defp registry_started? do
    case Process.whereis(@registry_name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp start_handle(key, url, clone_opts) do
    clone_opts = Keyword.put_new(clone_opts, :lazy, true)
    via_name = {:via, Registry, {@registry_name, key}}

    case clone_for_registry(url, clone_opts) do
      {:ok, repo} -> RepoHandle.start_link(repo, name: via_name)
      err -> err
    end
  end

  defp clone_for_registry(url, opts), do: Exgit.clone(url, opts)
end
