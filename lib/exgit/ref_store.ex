defprotocol Exgit.RefStore do
  @spec read(t, String.t()) :: {:ok, term()} | {:error, term()}
  def read(store, ref)

  @spec resolve(t, String.t()) :: {:ok, binary()} | {:error, term()}
  def resolve(store, ref)

  @spec write(t, String.t(), term(), keyword()) :: {:ok, t} | {:error, term()}
  def write(store, ref, value, opts)

  @spec delete(t, String.t()) :: {:ok, t} | {:error, term()}
  def delete(store, ref)

  @spec list(t, String.t()) :: [{String.t(), term()}]
  def list(store, prefix)
end
