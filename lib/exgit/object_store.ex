defprotocol Exgit.ObjectStore do
  @spec get(t, binary()) :: {:ok, Exgit.Object.t()} | {:error, term()}
  def get(store, sha)

  @spec put(t, Exgit.Object.t()) :: {:ok, binary(), t}
  def put(store, object)

  @spec has?(t, binary()) :: boolean()
  def has?(store, sha)

  @spec import_objects(t, [{atom(), binary(), binary()}]) :: {:ok, t}
  def import_objects(store, raw_objects)

  # ---------------------------------------------------------------------------
  # Phase 3+ streaming write API
  #
  # Allows object content to be written incrementally (one chunk at a time)
  # without ever holding the full uncompressed content in memory alongside
  # the compressed/stored form. The handle is an opaque term managed by each
  # store implementation.
  #
  # Typical flow:
  #
  #   {:ok, handle}          = ObjectStore.open_write(store, :blob, 500_000)
  #   {:ok, handle}          = ObjectStore.write_chunk(store, handle, chunk1)
  #   {:ok, handle}          = ObjectStore.write_chunk(store, handle, chunk2)
  #   {:ok, sha, new_store}  = ObjectStore.close_write(store, handle)
  #
  # On error (e.g. inflate_ratio_exceeded), call cancel_write/2 to release
  # any resources (open ports, temp files) without persisting the object:
  #
  #   :ok = ObjectStore.cancel_write(store, handle)
  # ---------------------------------------------------------------------------

  @doc """
  Open a streaming write session for an object of `type` and `expected_size`
  bytes (the declared uncompressed size from the pack header).

  Returns `{:ok, handle}` where handle is an opaque term, or
  `{:error, :not_supported}` for stores that do not implement the streaming API.
  """
  @spec open_write(t, Exgit.Object.object_type(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def open_write(store, type, expected_size)

  @doc """
  Append a chunk of uncompressed content to the in-progress write session.
  Returns `{:ok, updated_handle}`.
  """
  @spec write_chunk(t, term(), binary()) :: {:ok, term()} | {:error, term()}
  def write_chunk(store, handle, chunk)

  @doc """
  Finalise the write session: compute the object SHA, persist the object,
  and return the updated store. Returns `{:ok, sha, updated_store}`.
  """
  @spec close_write(t, term()) :: {:ok, binary(), t} | {:error, term()}
  def close_write(store, handle)

  @doc """
  Abort the write session and release any associated resources (open ports,
  temp files, etc.) without persisting the object. Always returns `:ok`.
  """
  @spec cancel_write(t, term()) :: :ok
  def cancel_write(store, handle)
end
