defmodule Exgit.Object.Hex do
  @moduledoc false

  @spec encode(binary()) :: String.t()
  def encode(<<_::binary-size(20)>> = raw), do: Base.encode16(raw, case: :lower)
  def encode(hex) when is_binary(hex) and byte_size(hex) == 40, do: hex

  @spec decode!(String.t()) :: binary()
  def decode!(hex) when byte_size(hex) == 40, do: Base.decode16!(hex, case: :mixed)

  @spec decode(String.t()) :: {:ok, binary()} | :error
  def decode(hex) when byte_size(hex) == 40, do: Base.decode16(hex, case: :mixed)
  def decode(_), do: :error
end
