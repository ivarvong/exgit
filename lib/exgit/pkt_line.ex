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
  `decode_stream/1` parses a concatenated pkt-line stream into
  `{:data, bin} | :flush | :delim | :response_end` tokens.
  Decoders never raise on malformed or truncated input — bad
  framing surfaces as an `{:error, {:malformed_pkt_line, snippet}}`
  value; see `Exgit.PropertiesTest` for the fuzz property.
  """

  @type packet :: {:data, binary()} | :flush | :delim | :response_end
  @type decode_error :: {:error, {:malformed_pkt_line, binary()}}

  # Largest payload a single pkt-line can carry: git caps the framed
  # length at 65520 bytes (LARGE_PACKET_MAX), minus the 4-byte header.
  @max_payload 65_516

  # How many bytes of the offending input to include in a
  # `:malformed_pkt_line` error detail.
  @error_snippet_bytes 40

  @doc """
  Frame a data payload as a pkt-line.

  Payloads are capped at #{@max_payload} bytes — git's
  `LARGE_PACKET_MAX` (65520) minus the 4-byte length header. Raises
  `ArgumentError` for oversized payloads: the length header is 4 hex
  digits, so silently encoding anything larger would corrupt the
  wire stream. Callers sending bulk data (e.g. sideband frames) must
  chunk it below the limit.
  """
  @spec encode(iodata()) :: iolist()
  def encode(data) do
    payload = IO.iodata_to_binary(data)

    if byte_size(payload) > @max_payload do
      raise ArgumentError,
            "pkt-line payload is #{byte_size(payload)} bytes; " <>
              "max is #{@max_payload} (LARGE_PACKET_MAX minus the 4-byte header)"
    end

    len = byte_size(payload) + 4
    [len |> Integer.to_string(16) |> String.pad_leading(4, "0"), payload]
  end

  @spec flush() :: binary()
  def flush, do: "0000"

  @spec delim() :: binary()
  def delim, do: "0001"

  @spec response_end() :: binary()
  def response_end, do: "0002"

  @doc """
  Lazily decode a concatenated pkt-line stream.

  Yields `t:packet/0` tokens. On malformed or truncated input the
  stream yields a final `{:error, {:malformed_pkt_line, snippet}}`
  token — `snippet` is up to #{@error_snippet_bytes} bytes of the
  offending input — and halts. Never raises on hostile bytes.
  """
  @spec decode_stream(binary()) :: Enumerable.t()
  def decode_stream(bytes) when is_binary(bytes) do
    Stream.unfold(bytes, fn
      :halted ->
        nil

      <<>> ->
        nil

      <<"0000", rest::binary>> ->
        {:flush, rest}

      <<"0001", rest::binary>> ->
        {:delim, rest}

      <<"0002", rest::binary>> ->
        {:response_end, rest}

      <<hex_len::binary-size(4), rest::binary>> = buf ->
        with {len, ""} <- Integer.parse(hex_len, 16),
             true <- len >= 4,
             payload_len = len - 4,
             <<payload::binary-size(^payload_len), tail::binary>> <- rest do
          {{:data, payload}, tail}
        else
          _ -> {{:error, {:malformed_pkt_line, snippet(buf)}}, :halted}
        end

      truncated ->
        {{:error, {:malformed_pkt_line, snippet(truncated)}}, :halted}
    end)
  end

  @doc """
  Eagerly decode a concatenated pkt-line stream.

  Returns the packet list, or `{:error, {:malformed_pkt_line, snippet}}`
  when the input contains bad or truncated framing. A malformed stream
  is rejected whole — packets decoded before the bad framing are
  discarded. Never raises on hostile bytes.
  """
  @spec decode_all(binary()) :: [packet()] | decode_error()
  def decode_all(bytes) when is_binary(bytes) do
    tokens = bytes |> decode_stream() |> Enum.to_list()

    case List.last(tokens) do
      {:error, _} = error -> error
      _ -> tokens
    end
  end

  defp snippet(bytes),
    do: binary_part(bytes, 0, min(byte_size(bytes), @error_snippet_bytes))
end
