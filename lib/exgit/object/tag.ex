defmodule Exgit.Object.Tag do
  @moduledoc """
  Git annotated tag object.

  Like `Exgit.Object.Commit`, a tag is represented as a message plus an
  **ordered list of headers**. Unknown headers and continuation lines
  (multi-line values such as embedded signatures) are preserved verbatim
  and in order, so `decode |> encode` is byte-exact and re-encoding a
  decoded tag never changes its SHA.

  The `:object` field caches the validated `object` header as a raw
  20-byte binary; `encode/1` reads only `:headers` and `:message`.
  Convenience accessors (`type/1`, `tag/1`, `tagger/1`) extract
  well-known headers.

  `decode/1` validates the `object` header as a 40-char hex string.
  Accessors on a decoded tag are infallible — a hostile remote cannot
  DoS a walk/diff by shipping a tag with non-hex header bytes. See
  `test/exgit/security/tag_malformed_hex_test.exs` for the
  regression.
  """

  alias Exgit.Object.Hex

  @enforce_keys [:object, :headers, :message]
  defstruct [:object, :headers, :message]

  @type header :: {name :: String.t(), value :: String.t()}
  @type t :: %__MODULE__{
          object: binary(),
          headers: [header()],
          message: String.t()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    object = Keyword.fetch!(opts, :object)
    type = Keyword.get(opts, :type, "commit")
    tag = Keyword.fetch!(opts, :tag)
    tagger = Keyword.get(opts, :tagger)
    message = Keyword.fetch!(opts, :message)

    # `Hex.encode/1` accepts either a raw 20-byte sha or a 40-char hex
    # string; the field always holds the raw form, the header the hex.
    object_hex = Hex.encode(object)

    headers =
      [{"object", object_hex}, {"type", type}, {"tag", tag}] ++
        if(tagger, do: [{"tagger", tagger}], else: [])

    %__MODULE__{object: Hex.decode!(object_hex), headers: headers, message: message}
  end

  @spec type(t()) :: String.t()
  def type(%__MODULE__{} = t), do: header!(t, "type")

  @spec tag(t()) :: String.t()
  def tag(%__MODULE__{} = t), do: header!(t, "tag")

  @spec tagger(t()) :: String.t() | nil
  def tagger(%__MODULE__{headers: hs}) do
    Enum.find_value(hs, fn
      {"tagger", v} -> v
      _ -> nil
    end)
  end

  defp header!(%__MODULE__{headers: hs}, name) do
    case Enum.find(hs, fn {n, _} -> n == name end) do
      {_, v} -> v
      nil -> raise KeyError, key: name
    end
  end

  @spec encode(t()) :: iolist()
  def encode(%__MODULE__{headers: headers, message: message}) do
    [
      Enum.map(headers, &encode_header/1),
      ?\n,
      message
    ]
  end

  defp encode_header({name, value}) do
    case String.split(value, "\n") do
      [single] -> [name, ?\s, single, ?\n]
      [first | rest] -> [name, ?\s, first, ?\n, Enum.map(rest, fn l -> [?\s, l, ?\n] end)]
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    case :binary.match(bytes, "\n\n") do
      {pos, 2} ->
        <<raw_headers::binary-size(^pos), "\n\n", message::binary>> = bytes

        case parse_headers(raw_headers) do
          {:ok, headers} ->
            # A tag must have object + type + tag. The `object` header
            # is additionally validated as 40-char hex so that the
            # `:object` field (and downstream walks) are infallible —
            # we never `raise` on the wire bytes.
            with :ok <- ensure_header(headers, "type"),
                 :ok <- ensure_header(headers, "tag"),
                 {:ok, object} <- fetch_object(headers) do
              {:ok, %__MODULE__{object: object, headers: headers, message: message}}
            end

          {:error, _} = err ->
            err
        end

      :nomatch ->
        {:error, :missing_message_separator}
    end
  rescue
    e -> {:error, {:decode_failed, e}}
  end

  defp ensure_header(headers, name) do
    if Enum.any?(headers, fn {n, _} -> n == name end),
      do: :ok,
      else: {:error, {:missing_header, name}}
  end

  defp fetch_object(headers) do
    case Enum.find(headers, fn {n, _} -> n == "object" end) do
      {_, hex} ->
        case Hex.decode(hex) do
          {:ok, bin} -> {:ok, bin}
          :error -> {:error, {:invalid_hex_header, "object", hex}}
        end

      nil ->
        {:error, {:missing_header, "object"}}
    end
  end

  # Parse headers preserving order. Continuation lines (lines starting with
  # a space) extend the previous header's value with a leading newline.
  # A continuation line appearing before any header is an error.
  defp parse_headers(raw) do
    lines = String.split(raw, "\n")

    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case {line, acc} do
        {" " <> rest, [{name, val} | tail]} ->
          {:cont, {:ok, [{name, val <> "\n" <> rest} | tail]}}

        {" " <> _, []} ->
          {:halt, {:error, :leading_continuation}}

        {line, acc} ->
          case String.split(line, " ", parts: 2) do
            [name, val] when name != "" -> {:cont, {:ok, [{name, val} | acc]}}
            _ -> {:halt, {:error, :malformed_header}}
          end
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  @spec sha(t()) :: Exgit.Object.sha()
  def sha(%__MODULE__{} = tag), do: Exgit.Object.compute_sha("tag", encode(tag))

  @spec sha_hex(t()) :: String.t()
  def sha_hex(%__MODULE__{} = tag), do: Base.encode16(sha(tag), case: :lower)
end
