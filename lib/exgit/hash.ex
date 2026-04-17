defmodule Exgit.Hash do
  @type sha :: binary()

  @callback id_length() :: pos_integer()
  @callback hex_length() :: pos_integer()
  @callback hash(iodata()) :: sha()
  @callback hash_hex(iodata()) :: String.t()
end
