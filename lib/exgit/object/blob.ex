defmodule Exgit.Object.Blob do
  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: binary()}

  @spec new(binary()) :: t()
  def new(data) when is_binary(data), do: %__MODULE__{data: data}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{data: data}), do: data

  @spec decode(binary()) :: {:ok, t()}
  def decode(bytes) when is_binary(bytes), do: {:ok, %__MODULE__{data: bytes}}

  @spec sha(t()) :: Exgit.Object.sha()
  def sha(%__MODULE__{data: data}), do: Exgit.Object.compute_sha("blob", data)

  @spec sha_hex(t()) :: String.t()
  def sha_hex(%__MODULE__{} = blob), do: Base.encode16(sha(blob), case: :lower)
end
