defmodule Exgit.Object.Tag do
  @moduledoc """
  Git annotated tag object.

  `decode/1` validates the `object` header as a 40-char hex string
  and stores it as the raw 20-byte binary. Accessors on a decoded
  tag are infallible — a hostile remote cannot DoS a walk/diff by
  shipping a tag with non-hex header bytes. See
  `test/exgit/security/tag_malformed_hex_test.exs` for the
  regression.
  """

  alias Exgit.Object.Hex

  @enforce_keys [:object, :type, :tag, :message]
  defstruct [:object, :type, :tag, :message, tagger: nil]

  @type t :: %__MODULE__{
          object: binary(),
          type: String.t(),
          tag: String.t(),
          tagger: String.t() | nil,
          message: String.t()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      object: Keyword.fetch!(opts, :object),
      type: Keyword.get(opts, :type, "commit"),
      tag: Keyword.fetch!(opts, :tag),
      tagger: Keyword.get(opts, :tagger),
      message: Keyword.fetch!(opts, :message)
    }
  end

  @spec encode(t()) :: iolist()
  def encode(%__MODULE__{} = t) do
    [
      "object ",
      Hex.encode(t.object),
      ?\n,
      "type ",
      t.type,
      ?\n,
      "tag ",
      t.tag,
      ?\n,
      encode_tagger(t.tagger),
      ?\n,
      t.message
    ]
  end

  defp encode_tagger(nil), do: []
  defp encode_tagger(tagger), do: ["tagger ", tagger, ?\n]

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    case :binary.match(bytes, "\n\n") do
      {pos, 2} ->
        <<raw_headers::binary-size(pos), "\n\n", message::binary>> = bytes

        case parse_headers(raw_headers) do
          {:ok, headers} ->
            with {:ok, object} <- Map.fetch(headers, :object),
                 {:ok, type} <- Map.fetch(headers, :type),
                 {:ok, tag} <- Map.fetch(headers, :tag) do
              {:ok,
               %__MODULE__{
                 object: object,
                 type: type,
                 tag: tag,
                 tagger: Map.get(headers, :tagger),
                 message: message
               }}
            else
              :error -> {:error, :missing_header}
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

  # Parse headers into a map. If any `object` header has non-hex content,
  # return an error — a hostile remote could otherwise DoS downstream
  # accessors. We never `raise` on the wire bytes.
  defp parse_headers(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, " ", parts: 2) do
        ["object", hex] ->
          case Hex.decode(hex) do
            {:ok, bin} -> {:cont, {:ok, Map.put(acc, :object, bin)}}
            :error -> {:halt, {:error, {:invalid_hex_header, "object", hex}}}
          end

        ["type", val] ->
          {:cont, {:ok, Map.put(acc, :type, val)}}

        ["tag", val] ->
          {:cont, {:ok, Map.put(acc, :tag, val)}}

        ["tagger", val] ->
          {:cont, {:ok, Map.put(acc, :tagger, val)}}

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  @spec sha(t()) :: Exgit.Object.sha()
  def sha(%__MODULE__{} = tag), do: Exgit.Object.compute_sha("tag", encode(tag))

  @spec sha_hex(t()) :: String.t()
  def sha_hex(%__MODULE__{} = tag), do: Base.encode16(sha(tag), case: :lower)
end
