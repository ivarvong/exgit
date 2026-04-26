defmodule Exgit.PktLine.Decoder do
  @moduledoc """
  Incremental, stateful pkt-line decoder for streaming HTTP bodies.

  `Exgit.PktLine.decode_stream/1` requires the entire response in a
  single binary; this module accepts arbitrary chunks (as they arrive
  from the network), yields complete packets per chunk, and retains
  any partial trailing bytes in the decoder state for the next feed.

  Used by `Exgit.Transport.HTTP` to feed `Req.request(into: fun)`
  chunks into pkt-line decoding without ever materializing the full
  response. With sideband-all framing on a multi-GB pack, this is
  the difference between bounded memory and an OOM.

  ## Usage

      decoder = Decoder.new()
      {:ok, decoder, pkts} = Decoder.feed(decoder, chunk1)
      # ... handle pkts ...
      {:ok, decoder, pkts} = Decoder.feed(decoder, chunk2)
      # ... handle pkts ...
      :ok = Decoder.finalize(decoder)
  """

  alias Exgit.PktLine

  @enforce_keys [:buffer]
  defstruct buffer: <<>>

  @type t :: %__MODULE__{buffer: binary()}

  @spec new() :: t()
  def new, do: %__MODULE__{buffer: <<>>}

  @doc """
  Feed a chunk of bytes into the decoder. Returns the updated decoder
  and any complete packets that became decodable from `buffer ++ chunk`.

  Returns `{:error, reason}` on malformed framing (length-prefix that
  is not valid hex or claims a length below the 4-byte header).
  """
  @spec feed(t(), binary()) ::
          {:ok, t(), [PktLine.packet()]} | {:error, term()}
  def feed(%__MODULE__{buffer: buf}, chunk) when is_binary(chunk) do
    drain(<<buf::binary, chunk::binary>>, [])
  end

  @doc """
  Assert the decoder has consumed all input cleanly. Returns
  `{:error, {:truncated, n}}` if `n` bytes of an incomplete pkt-line
  remain in the buffer.
  """
  @spec finalize(t()) :: :ok | {:error, {:truncated, non_neg_integer()}}
  def finalize(%__MODULE__{buffer: <<>>}), do: :ok
  def finalize(%__MODULE__{buffer: rest}), do: {:error, {:truncated, byte_size(rest)}}

  # --- internals ---

  defp drain(<<>>, acc), do: {:ok, %__MODULE__{buffer: <<>>}, Enum.reverse(acc)}

  defp drain(<<"0000", rest::binary>>, acc), do: drain(rest, [:flush | acc])
  defp drain(<<"0001", rest::binary>>, acc), do: drain(rest, [:delim | acc])
  defp drain(<<"0002", rest::binary>>, acc), do: drain(rest, [:response_end | acc])

  defp drain(<<hex::binary-size(4), rest::binary>> = buf, acc) do
    case Integer.parse(hex, 16) do
      {len, ""} when len >= 4 ->
        payload_len = len - 4

        case rest do
          <<payload::binary-size(payload_len), tail::binary>> ->
            drain(tail, [{:data, payload} | acc])

          # Payload not fully arrived — preserve the WHOLE pkt-line
          # (header + partial payload) in the buffer for the next feed.
          _ ->
            {:ok, %__MODULE__{buffer: buf}, Enum.reverse(acc)}
        end

      _ ->
        {:error, {:malformed_length, hex}}
    end
  end

  # Fewer than 4 header bytes — keep what we have.
  defp drain(buf, acc) when byte_size(buf) < 4 do
    {:ok, %__MODULE__{buffer: buf}, Enum.reverse(acc)}
  end
end
