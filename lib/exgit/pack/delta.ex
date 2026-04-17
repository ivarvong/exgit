defmodule Exgit.Pack.Delta do
  @moduledoc false

  @spec apply(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def apply(base, delta) do
    {_base_size, delta} = decode_size(delta)
    {result_size, delta} = decode_size(delta)
    result = apply_instructions(delta, base, [])

    case result do
      {:ok, iodata} ->
        bin = IO.iodata_to_binary(iodata)

        if byte_size(bin) == result_size do
          {:ok, bin}
        else
          {:error, {:size_mismatch, byte_size(bin), result_size}}
        end

      error ->
        error
    end
  end

  defp apply_instructions(<<>>, _base, acc), do: {:ok, Enum.reverse(acc)}

  # Insert instruction: MSB == 0, lower 7 bits = length of data to insert
  defp apply_instructions(<<0, _rest::binary>>, _base, _acc) do
    {:error, :reserved_delta_instruction}
  end

  defp apply_instructions(<<byte, rest::binary>>, base, acc) when byte < 128 do
    insert_len = byte
    <<data::binary-size(insert_len), rest::binary>> = rest
    apply_instructions(rest, base, [data | acc])
  end

  # Copy instruction: MSB == 1, lower 7 bits encode which offset/size bytes follow
  defp apply_instructions(<<byte, rest::binary>>, base, acc) when byte >= 128 do
    {offset, rest} = decode_copy_offset(byte, rest)
    {size, rest} = decode_copy_size(byte, rest)
    size = if size == 0, do: 0x10000, else: size
    chunk = binary_part(base, offset, size)
    apply_instructions(rest, base, [chunk | acc])
  end

  defp decode_copy_offset(cmd, rest) do
    {b0, rest} = if Bitwise.band(cmd, 0x01) != 0, do: take_byte(rest), else: {0, rest}
    {b1, rest} = if Bitwise.band(cmd, 0x02) != 0, do: take_byte(rest), else: {0, rest}
    {b2, rest} = if Bitwise.band(cmd, 0x04) != 0, do: take_byte(rest), else: {0, rest}
    {b3, rest} = if Bitwise.band(cmd, 0x08) != 0, do: take_byte(rest), else: {0, rest}

    offset =
      Bitwise.bor(
        Bitwise.bor(b0, Bitwise.bsl(b1, 8)),
        Bitwise.bor(Bitwise.bsl(b2, 16), Bitwise.bsl(b3, 24))
      )

    {offset, rest}
  end

  defp decode_copy_size(cmd, rest) do
    {b0, rest} = if Bitwise.band(cmd, 0x10) != 0, do: take_byte(rest), else: {0, rest}
    {b1, rest} = if Bitwise.band(cmd, 0x20) != 0, do: take_byte(rest), else: {0, rest}
    {b2, rest} = if Bitwise.band(cmd, 0x40) != 0, do: take_byte(rest), else: {0, rest}

    size =
      Bitwise.bor(
        b0,
        Bitwise.bor(Bitwise.bsl(b1, 8), Bitwise.bsl(b2, 16))
      )

    {size, rest}
  end

  defp take_byte(<<b, rest::binary>>), do: {b, rest}

  defp decode_size(data), do: decode_size(data, 0, 0)

  defp decode_size(<<byte, rest::binary>>, acc, shift) do
    value = Bitwise.bor(acc, Bitwise.bsl(Bitwise.band(byte, 0x7F), shift))

    if Bitwise.band(byte, 0x80) == 0 do
      {value, rest}
    else
      decode_size(rest, value, shift + 7)
    end
  end
end
