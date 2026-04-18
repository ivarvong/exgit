defmodule Exgit.Hash do
  @moduledoc """
  Behaviour for a git object-id hash function.

  Implemented by `Exgit.Hash.SHA1`. A SHA-256 repo implementation
  would add a sibling module implementing this behaviour. The rest
  of the library dispatches through `Exgit.Object.compute_sha/2`
  which uses SHA-1 today.
  """

  @type sha :: binary()

  @callback id_length() :: pos_integer()
  @callback hex_length() :: pos_integer()
  @callback hash(iodata()) :: sha()
  @callback hash_hex(iodata()) :: String.t()
end
