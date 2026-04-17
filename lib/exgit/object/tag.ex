defmodule Exgit.Object.Tag do
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

  @spec encode(t()) :: iodata()
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
        headers = parse_headers(raw_headers)

        {:ok,
         %__MODULE__{
           object: Map.fetch!(headers, :object),
           type: Map.fetch!(headers, :type),
           tag: Map.fetch!(headers, :tag),
           tagger: Map.get(headers, :tagger),
           message: message
         }}

      :nomatch ->
        {:error, :missing_message_separator}
    end
  rescue
    e -> {:error, {:decode_failed, e}}
  end

  defp parse_headers(raw) do
    raw
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, " ", parts: 2) do
        ["object", hex] -> Map.put(acc, :object, Hex.decode!(hex))
        ["type", val] -> Map.put(acc, :type, val)
        ["tag", val] -> Map.put(acc, :tag, val)
        ["tagger", val] -> Map.put(acc, :tagger, val)
        _ -> acc
      end
    end)
  end

  @spec sha(t()) :: Exgit.Object.sha()
  def sha(%__MODULE__{} = tag), do: Exgit.Object.compute_sha("tag", encode(tag))

  @spec sha_hex(t()) :: String.t()
  def sha_hex(%__MODULE__{} = tag), do: Base.encode16(sha(tag), case: :lower)
end
