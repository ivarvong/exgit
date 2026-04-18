defmodule Exgit.PktLine do
  @moduledoc """
  Git's [pkt-line](https://git-scm.com/docs/gitformat-pack)
  framing.

  Each pkt-line is 4 ASCII hex bytes of length (including the
  length header itself) followed by the payload, with three
  sentinels:

    * `0000` — flush
    * `0001` — delim (protocol v2)
    * `0002` — response-end

  `encode/1` emits the framed bytes for a data payload;
  `decode_stream/1` parses a concatenated pkt-line stream into a
  list of `{:data, bin} | :flush | :delim | :response_end` tokens.
  Decoders never raise on truncated input; see
  `Exgit.PropertiesTest` for the roundtrip property.
  """

  @type packet :: {:data, binary()} | :flush | :delim | :response_end

  @spec encode(iodata()) :: iolist()
  def encode(data) do
    payload = IO.iodata_to_binary(data)
    len = byte_size(payload) + 4
    [len |> Integer.to_string(16) |> String.pad_leading(4, "0"), payload]
  end

  @spec flush() :: binary()
  def flush, do: "0000"

  @spec delim() :: binary()
  def delim, do: "0001"

  @spec response_end() :: binary()
  def response_end, do: "0002"

  @spec decode_stream(binary()) :: Enumerable.t()
  def decode_stream(bytes) when is_binary(bytes) do
    Stream.unfold(bytes, fn
      <<>> ->
        nil

      <<"0000", rest::binary>> ->
        {:flush, rest}

      <<"0001", rest::binary>> ->
        {:delim, rest}

      <<"0002", rest::binary>> ->
        {:response_end, rest}

      <<hex_len::binary-size(4), rest::binary>> ->
        with {len, ""} <- Integer.parse(hex_len, 16),
             true <- len >= 4,
             payload_len = len - 4,
             <<payload::binary-size(payload_len), rest::binary>> <- rest do
          {{:data, payload}, rest}
        else
          _ ->
            raise ArgumentError,
                  "malformed pkt-line at: #{inspect(binary_part(hex_len <> rest, 0, min(byte_size(hex_len <> rest), 40)))}"
        end

      truncated ->
        raise ArgumentError, "truncated pkt-line header: #{inspect(truncated)}"
    end)
  end

  @spec decode_all(binary()) :: [packet()]
  def decode_all(bytes) when is_binary(bytes) do
    decode_stream(bytes) |> Enum.to_list()
  end
end
