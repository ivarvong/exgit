defmodule Exgit.ObjectStore.SharedPromisor do
  @moduledoc """
  GenServer wrapper around `Exgit.ObjectStore.Promisor` that
  serializes cache access across processes.

  The plain `Promisor` is a pure value: two concurrent
  `resolve(p, sha_a)` / `resolve(p, sha_b)` calls from the same `p`
  each fetch independently and only one caller's grown cache
  survives — a benign but wasteful **cache race**.

  For workloads that genuinely do concurrent bulk reads against the
  same repo (a grep agent spawning N tasks, a CI worker hydrating a
  cache from many branches in parallel), wrap the Promisor in a
  SharedPromisor:

      {:ok, pid} = SharedPromisor.start_link(promisor)

      # Both tasks see + grow the same cache, serialized by the
      # GenServer. No race, no duplicate fetches.
      Task.async(fn -> SharedPromisor.resolve(pid, sha_a) end)
      Task.async(fn -> SharedPromisor.resolve(pid, sha_b) end)

  The API mirrors `Promisor.resolve/2` / `put/2` / `empty?/1` /
  `fetch_with_filter/3` — each call acquires a GenServer lock,
  mutates the internal Promisor, and releases.

  ## When NOT to use this

    * Single-threaded agent loops. The plain pure-value Promisor is
      faster (no message-passing overhead).
    * Short-lived scripts. The setup cost of spinning up a
      GenServer is ~200µs, usually more than the work saved.
    * Repos you'd rather snapshot. Share the `%Promisor{}` struct
      by value; two tasks holding the same struct see the same
      cache deterministically.

  ## Failure semantics

  If the wrapped Promisor call raises (e.g. a transport
  misconfiguration), the exception propagates through to the
  caller and the GenServer terminates. Supervise it under a
  `:one_for_one` strategy in your app tree if you want
  auto-restart; callers will need to re-discover the new pid and
  re-seed if they want state to persist across restarts.

  ## Telemetry

  Each public call emits a `[:exgit, :object_store, :shared_promisor, op]`
  span event where `op` is `:resolve | :put | :has? | :get`. Use this
  to track lock-contention latency separately from the underlying
  `[:exgit, :object_store, :*]` Promisor events.
  """

  use GenServer

  alias Exgit.ObjectStore.Promisor

  @type server :: GenServer.server()

  # --- Public API ---

  @doc """
  Start a SharedPromisor process wrapping the given Promisor.

  Accepts all the usual `GenServer.start_link/3` options (`:name`,
  `:timeout`, etc.) plus a required `promisor` key.

  ## Examples

      {:ok, pid} = SharedPromisor.start_link(my_promisor)
      {:ok, pid} = SharedPromisor.start_link(my_promisor, name: MyApp.Cache)

  """
  @spec start_link(Promisor.t(), GenServer.options()) :: GenServer.on_start()
  def start_link(%Promisor{} = promisor, opts \\ []) do
    GenServer.start_link(__MODULE__, promisor, opts)
  end

  @doc """
  Look up `sha`, fetching from the transport on cache miss.

  Unlike `Promisor.resolve/2`, does NOT return a promisor in the
  success tuple — the cache grew inside the GenServer, and the
  next call will see the updated state automatically.

  Returns one of:

    * `{:ok, object}` — cache hit or successful fetch
    * `{:error, reason}` — transport failure, cache unchanged
    * `{:error, :not_found}` — fetch returned a pack that didn't
      contain the requested SHA; sibling objects that WERE
      returned are now in the cache and will benefit future calls.
  """
  @spec resolve(server(), binary(), timeout()) ::
          {:ok, Exgit.Object.t()} | {:error, term()}
  def resolve(server, sha, timeout \\ 30_000) do
    GenServer.call(server, {:resolve, sha}, timeout)
  end

  @doc """
  Insert an object into the shared cache. Returns `{:ok, sha}` or
  `{:error, :cache_overfull}` when the wrapped Promisor has
  `:on_overfull => :error`.
  """
  @spec put(server(), Exgit.Object.t(), timeout()) ::
          {:ok, binary()} | {:error, :cache_overfull}
  def put(server, object, timeout \\ 30_000) do
    GenServer.call(server, {:put, object}, timeout)
  end

  @doc "True if `sha` is in the local cache. Does NOT trigger a fetch."
  @spec has_object?(server(), binary(), timeout()) :: boolean()
  def has_object?(server, sha, timeout \\ 5_000) do
    GenServer.call(server, {:has?, sha}, timeout)
  end

  @doc "Pure-read lookup. Does NOT grow the cache; returns `{:error, :not_found}` on miss."
  @spec get(server(), binary(), timeout()) ::
          {:ok, Exgit.Object.t()} | {:error, term()}
  def get(server, sha, timeout \\ 5_000) do
    GenServer.call(server, {:get, sha}, timeout)
  end

  @doc "True if the wrapped cache has no objects."
  @spec empty?(server(), timeout()) :: boolean()
  def empty?(server, timeout \\ 5_000) do
    GenServer.call(server, :empty?, timeout)
  end

  @doc """
  Snapshot the current Promisor state. Useful for serialization,
  debugging, or handing back a pure value after the shared cache
  has served its purpose.
  """
  @spec snapshot(server(), timeout()) :: Promisor.t()
  def snapshot(server, timeout \\ 5_000) do
    GenServer.call(server, :snapshot, timeout)
  end

  @doc """
  Replace the wrapped Promisor. Use sparingly — this discards the
  current cache. Intended for testing and for swapping transports.
  """
  @spec replace(server(), Promisor.t(), timeout()) :: :ok
  def replace(server, %Promisor{} = new_promisor, timeout \\ 5_000) do
    GenServer.call(server, {:replace, new_promisor}, timeout)
  end

  @doc """
  Fetch with an explicit filter spec and merge results into the
  cache. See `Promisor.fetch_with_filter/3`.
  """
  @spec fetch_with_filter(server(), [binary()], keyword(), timeout()) ::
          :ok | {:error, term()}
  def fetch_with_filter(server, wants, opts, timeout \\ 60_000) do
    GenServer.call(server, {:fetch_with_filter, wants, opts}, timeout)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(%Promisor{} = p), do: {:ok, p}

  @impl true
  def handle_call({:resolve, sha}, _from, p) do
    span(:resolve, %{sha: sha}, fn ->
      case Promisor.resolve(p, sha) do
        {:ok, obj, new_p} ->
          {{:reply, {:ok, obj}, new_p}, %{hit?: new_p == p}}

        {:error, reason, new_p} ->
          # Fetch-but-not-found: cache grew with sibling objects,
          # state update is kept.
          {{:reply, {:error, reason}, new_p}, %{hit?: false, partial?: true}}

        {:error, _} = err ->
          {{:reply, err, p}, %{hit?: false}}
      end
    end)
  end

  def handle_call({:put, object}, _from, p) do
    span(:put, %{}, fn ->
      case Promisor.put(p, object) do
        {:ok, sha, new_p} ->
          {{:reply, {:ok, sha}, new_p}, %{sha: sha}}

        {:error, :cache_overfull, new_p} ->
          {{:reply, {:error, :cache_overfull}, new_p}, %{overfull: true}}
      end
    end)
  end

  def handle_call({:has?, sha}, _from, p) do
    span(:has?, %{sha: sha}, fn ->
      present? = Promisor.has_object?(p, sha)
      {{:reply, present?, p}, %{present?: present?}}
    end)
  end

  def handle_call({:get, sha}, _from, p) do
    span(:get, %{sha: sha}, fn ->
      result = Exgit.ObjectStore.get(p, sha)
      {{:reply, result, p}, %{hit?: match?({:ok, _}, result)}}
    end)
  end

  def handle_call(:empty?, _from, p) do
    {:reply, Promisor.empty?(p), p}
  end

  def handle_call(:snapshot, _from, p) do
    {:reply, p, p}
  end

  def handle_call({:replace, new_p}, _from, _old_p) do
    {:reply, :ok, new_p}
  end

  def handle_call({:fetch_with_filter, wants, opts}, _from, p) do
    case Promisor.fetch_with_filter(p, wants, opts) do
      {:ok, new_p} -> {:reply, :ok, new_p}
      {:error, _} = err -> {:reply, err, p}
    end
  end

  # --- Internal ---

  # Wrap a handle_call body in a telemetry span. The body returns
  # `{reply_tuple, meta}` where `meta` is added to the stop-event
  # metadata. `reply_tuple` is passed through unchanged.
  defp span(op, base_meta, fun) do
    Exgit.Telemetry.span(
      [:exgit, :object_store, :shared_promisor, op],
      base_meta,
      fn ->
        {reply, extra_meta} = fun.()
        {:span, reply, extra_meta}
      end
    )
  end
end
