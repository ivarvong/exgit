defmodule Exgit.Test.PackBuilder do
  @moduledoc """
  Helpers to construct valid pack bytes for tests. Intentionally minimal —
  builds non-delta objects, OFS_DELTA entries, and REF_DELTA entries.
  """

  alias Exgit.Pack.Common

  @doc """
  Build a pack from a list of entries. Each entry is one of:

    - `{:full, type_atom, content_bytes}` — stored as a normal object
    - `{:ref_delta, base_sha20, base_content_bytes, result_bytes}` — emits a
      REF_DELTA whose delta payload reconstructs `result_bytes` from
      `base_content_bytes`. `base_sha20` is the binary SHA (20 bytes) of the
      base object of type `base_type`.
    - `{:ofs_delta, neg_offset, base_content_bytes, result_bytes}` — emits
      an OFS_DELTA pointing to a base earlier in this pack.

  Returns the complete pack binary including the trailing SHA-1.
  """
  def build(entries) do
    header = <<
      Common.pack_signature()::binary,
      Common.pack_version()::32-big,
      length(entries)::32-big
    >>

    body =
      entries
      |> Enum.map(&encode_entry/1)
      |> IO.iodata_to_binary()

    data = header <> body
    data <> :crypto.hash(:sha, data)
  end

  defp encode_entry({:full, type_atom, content}) do
    type_code = Common.type_code(type_atom)
    type_size = Common.encode_type_size_varint(type_code, byte_size(content))
    [type_size, deflate(content)]
  end

  defp encode_entry({:ref_delta, base_sha20, base_content, result}) do
    delta = build_full_copy_delta(base_content, result)
    type_size = Common.encode_type_size_varint(Common.obj_ref_delta(), byte_size(delta))
    [type_size, base_sha20, deflate(delta)]
  end

  defp encode_entry({:ofs_delta, neg_offset, base_content, result}) do
    delta = build_full_copy_delta(base_content, result)
    type_size = Common.encode_type_size_varint(Common.obj_ofs_delta(), byte_size(delta))
    [type_size, Common.encode_ofs_varint(neg_offset), deflate(delta)]
  end

  # Build a trivial delta that ignores the base and just inserts the result
  # bytes. This isn't how real packs encode deltas (real packs heavily use
  # copy), but the pack-reader contract accepts any valid delta.
  defp build_full_copy_delta(base, result) do
    base_size = encode_size(byte_size(base))
    result_size = encode_size(byte_size(result))

    # Chunk result into <=127-byte inserts.
    inserts = chunk_inserts(result)
    IO.iodata_to_binary([base_size, result_size, inserts])
  end

  defp chunk_inserts(<<>>), do: []

  defp chunk_inserts(data) do
    take = min(127, byte_size(data))
    <<chunk::binary-size(take), rest::binary>> = data
    [<<take>>, chunk | chunk_inserts(rest)]
  end

  # Little-endian varint used by delta size encoding (same shape as
  # Common.encode_varint).
  defp encode_size(n) when n < 128, do: <<n>>

  defp encode_size(n) do
    <<Bitwise.bor(Bitwise.band(n, 0x7F), 0x80)>> <> encode_size(Bitwise.bsr(n, 7))
  end

  defp deflate(data) do
    z = :zlib.open()
    :zlib.deflateInit(z, 6)
    compressed = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(compressed)
  end
end
