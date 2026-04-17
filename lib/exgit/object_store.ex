defprotocol Exgit.ObjectStore do
  @spec get(t, binary()) :: {:ok, Exgit.Object.t()} | {:error, term()}
  def get(store, sha)

  @spec put(t, Exgit.Object.t()) :: {:ok, binary(), t}
  def put(store, object)

  @spec has?(t, binary()) :: boolean()
  def has?(store, sha)

  @spec import_objects(t, [{atom(), binary(), binary()}]) :: {:ok, t}
  def import_objects(store, raw_objects)
end
