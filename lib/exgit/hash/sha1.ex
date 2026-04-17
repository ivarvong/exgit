defmodule Exgit.Hash.SHA1 do
  @behaviour Exgit.Hash

  @impl true
  def id_length, do: 20

  @impl true
  def hex_length, do: 40

  @impl true
  def hash(data), do: :crypto.hash(:sha, data)

  @impl true
  def hash_hex(data), do: Base.encode16(hash(data), case: :lower)
end
