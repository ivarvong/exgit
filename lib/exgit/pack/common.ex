defmodule Exgit.Pack.Common do
  @moduledoc false

  # Pack object type codes
  @obj_commit 1
  @obj_tree 2
  @obj_blob 3
  @obj_tag 4
  @obj_ofs_delta 6
  @obj_ref_delta 7

  def obj_commit, do: @obj_commit
  def obj_tree, do: @obj_tree
  def obj_blob, do: @obj_blob
  def obj_tag, do: @obj_tag
  def obj_ofs_delta, do: @obj_ofs_delta
  def obj_ref_delta, do: @obj_ref_delta

  @spec type_code(atom()) :: 1 | 2 | 3 | 4
  def type_code(:commit), do: @obj_commit
  def type_code(:tree), do: @obj_tree
  def type_code(:blob), do: @obj_blob
  def type_code(:tag), do: @obj_tag

  @spec type_atom(1 | 2 | 3 | 4) :: atom()
  def type_atom(@obj_commit), do: :commit
  def type_atom(@obj_tree), do: :tree
  def type_atom(@obj_blob), do: :blob
  def type_atom(@obj_tag), do: :tag

  @pack_signature "PACK"
  @pack_version 2

  def pack_signature, do: @pack_signature
  def pack_version, do: @pack_version

  @spec encode_type_size_varint(integer(), integer()) :: binary()
  def encode_type_size_varint(type, size) do
    # First byte: MSB | type (3 bits) | size (4 bits)
    first_nibble = Bitwise.band(size, 0x0F)
    rest_size = Bitwise.bsr(size, 4)
    first_byte = Bitwise.bor(Bitwise.bsl(type, 4), first_nibble)

    if rest_size == 0 do
      <<first_byte>>
    else
      <<Bitwise.bor(first_byte, 0x80)>> <> encode_varint(rest_size)
    end
  end

  @spec decode_type_size_varint(binary()) ::
          {integer(), integer(), binary()} | {:error, :truncated}
  def decode_type_size_varint(<<byte, rest::binary>>) do
    type = Bitwise.band(Bitwise.bsr(byte, 4), 0x07)
    size = Bitwise.band(byte, 0x0F)

    if Bitwise.band(byte, 0x80) == 0 do
      {type, size, rest}
    else
      case decode_varint(rest) do
        {:error, _} = err ->
          err

        {more_size, rest} ->
          {type, Bitwise.bor(size, Bitwise.bsl(more_size, 4)), rest}
      end
    end
  end

  def decode_type_size_varint(<<>>), do: {:error, :truncated}

  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(n) when n < 128, do: <<n>>

  def encode_varint(n) do
    <<Bitwise.bor(Bitwise.band(n, 0x7F), 0x80)>> <>
      encode_varint(Bitwise.bsr(n, 7))
  end

  @spec decode_varint(binary()) :: {non_neg_integer(), binary()} | {:error, :truncated}
  def decode_varint(data), do: decode_varint(data, 0, 0)

  defp decode_varint(<<byte, rest::binary>>, acc, shift) do
    value = Bitwise.bor(acc, Bitwise.bsl(Bitwise.band(byte, 0x7F), shift))

    if Bitwise.band(byte, 0x80) == 0 do
      {value, rest}
    else
      decode_varint(rest, value, shift + 7)
    end
  end

  defp decode_varint(<<>>, _acc, _shift), do: {:error, :truncated}

  @spec encode_ofs_varint(non_neg_integer()) :: binary()
  def encode_ofs_varint(n) do
    # OFS delta uses a different varint encoding where continuation bytes
    # add 1 to the accumulated value before shifting.
    encode_ofs_varint_bytes(n, [])
  end

  defp encode_ofs_varint_bytes(n, []) do
    byte = Bitwise.band(n, 0x7F)
    remaining = Bitwise.bsr(n, 7)

    if remaining == 0 do
      <<byte>>
    else
      encode_ofs_varint_bytes(remaining - 1, [byte])
    end
  end

  defp encode_ofs_varint_bytes(n, acc) do
    byte = Bitwise.bor(Bitwise.band(n, 0x7F), 0x80)
    remaining = Bitwise.bsr(n, 7)

    if remaining == 0 do
      IO.iodata_to_binary([byte | acc])
    else
      encode_ofs_varint_bytes(remaining - 1, [byte | acc])
    end
  end

  @spec decode_ofs_varint(binary()) :: {non_neg_integer(), binary()} | {:error, :truncated}
  def decode_ofs_varint(<<byte, rest::binary>>) do
    n = Bitwise.band(byte, 0x7F)

    if Bitwise.band(byte, 0x80) == 0 do
      {n, rest}
    else
      decode_ofs_varint_cont(rest, n)
    end
  end

  def decode_ofs_varint(<<>>), do: {:error, :truncated}

  defp decode_ofs_varint_cont(<<byte, rest::binary>>, acc) do
    n = Bitwise.bor(Bitwise.bsl(acc + 1, 7), Bitwise.band(byte, 0x7F))

    if Bitwise.band(byte, 0x80) == 0 do
      {n, rest}
    else
      decode_ofs_varint_cont(rest, n)
    end
  end

  defp decode_ofs_varint_cont(<<>>, _acc), do: {:error, :truncated}
end
