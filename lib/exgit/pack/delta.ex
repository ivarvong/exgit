defmodule Exgit.Pack.Delta do
  @moduledoc """
  Apply git's pack delta format against a base object.

  Every path returns `{:ok, bytes} | {:error, reason}`. Hostile input —
  truncated headers, out-of-bounds copy offsets, insert length longer
  than payload, reserved 0x00 opcode, size-mismatches — produces a
  tagged error; none raise.
  """

  import Bitwise

  # Guard against pathological result sizes. A delta claiming 1 GiB is
  # almost certainly malicious; callers can override via the second-arg
  # opts keyword.
  @default_max_result_bytes 100 * 1024 * 1024

  @spec apply(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def apply(base, delta, opts \\ [])

  def apply(base, delta, _opts)
      when not is_binary(base) or not is_binary(delta) do
    {:error, :not_a_binary}
  end

  def apply(base, delta, opts) do
    max_result = Keyword.get(opts, :max_result_bytes, @default_max_result_bytes)

    with {:ok, _base_size, rest} <- decode_size(delta),
         {:ok, result_size, rest} <- decode_size(rest),
         :ok <- check_result_size(result_size, max_result),
         {:ok, iodata} <- apply_instructions(rest, base, result_size, []) do
      bin = IO.iodata_to_binary(iodata)

      if byte_size(bin) == result_size do
        {:ok, bin}
      else
        {:error, {:size_mismatch, byte_size(bin), result_size}}
      end
    end
  end

  defp check_result_size(n, max) when n > max,
    do: {:error, {:delta_result_too_large, n, max}}

  defp check_result_size(_, _), do: :ok

  # Track remaining output budget; stop cleanly if the instructions try
  # to produce more than the declared result size.
  defp apply_instructions(<<>>, _base, _remaining, acc), do: {:ok, Enum.reverse(acc)}

  defp apply_instructions(<<0, _rest::binary>>, _base, _rem, _acc) do
    {:error, :reserved_delta_instruction}
  end

  # Insert: `byte` in 1..127 = raw byte count of inline payload.
  defp apply_instructions(<<byte, rest::binary>>, base, remaining, acc)
       when byte > 0 and byte < 128 do
    cond do
      byte_size(rest) < byte ->
        {:error, :insert_truncated}

      byte > remaining ->
        {:error, :insert_exceeds_result_size}

      true ->
        <<data::binary-size(byte), more::binary>> = rest
        apply_instructions(more, base, remaining - byte, [data | acc])
    end
  end

  # Copy: MSB set = copy from base.
  defp apply_instructions(<<byte, rest::binary>>, base, remaining, acc) when byte >= 128 do
    with {:ok, offset, rest} <- decode_copy_offset(byte, rest),
         {:ok, size, rest} <- decode_copy_size(byte, rest) do
      size = if size == 0, do: 0x10000, else: size

      cond do
        offset < 0 or offset > byte_size(base) ->
          {:error, {:copy_out_of_range, offset, byte_size(base)}}

        offset + size > byte_size(base) ->
          {:error, {:copy_out_of_range, offset + size, byte_size(base)}}

        size > remaining ->
          {:error, :copy_exceeds_result_size}

        true ->
          chunk = binary_part(base, offset, size)
          apply_instructions(rest, base, remaining - size, [chunk | acc])
      end
    end
  end

  defp decode_copy_offset(cmd, rest) do
    with {:ok, b0, rest} <- maybe_take_byte(rest, band(cmd, 0x01) != 0),
         {:ok, b1, rest} <- maybe_take_byte(rest, band(cmd, 0x02) != 0),
         {:ok, b2, rest} <- maybe_take_byte(rest, band(cmd, 0x04) != 0),
         {:ok, b3, rest} <- maybe_take_byte(rest, band(cmd, 0x08) != 0) do
      offset = bor(bor(b0, bsl(b1, 8)), bor(bsl(b2, 16), bsl(b3, 24)))
      {:ok, offset, rest}
    end
  end

  defp decode_copy_size(cmd, rest) do
    with {:ok, b0, rest} <- maybe_take_byte(rest, band(cmd, 0x10) != 0),
         {:ok, b1, rest} <- maybe_take_byte(rest, band(cmd, 0x20) != 0),
         {:ok, b2, rest} <- maybe_take_byte(rest, band(cmd, 0x40) != 0) do
      size = bor(b0, bor(bsl(b1, 8), bsl(b2, 16)))
      {:ok, size, rest}
    end
  end

  defp maybe_take_byte(rest, false), do: {:ok, 0, rest}
  defp maybe_take_byte(<<b, rest::binary>>, true), do: {:ok, b, rest}
  defp maybe_take_byte(<<>>, true), do: {:error, :copy_op_truncated}

  defp decode_size(data), do: decode_size(data, 0, 0)

  defp decode_size(<<byte, rest::binary>>, acc, shift) do
    value = bor(acc, bsl(band(byte, 0x7F), shift))

    if band(byte, 0x80) == 0 do
      {:ok, value, rest}
    else
      decode_size(rest, value, shift + 7)
    end
  end

  defp decode_size(<<>>, _acc, _shift), do: {:error, :size_header_truncated}
end
