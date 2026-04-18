defmodule Exgit.Pack.Writer do
  @moduledoc """
  Build a pack (`build/1`) and optionally its `.idx` index
  (`build_with_index/1`) from a list of objects.

  The idx output is v2 format and verifies clean with `git
  verify-pack`. Objects are written as full (non-delta) compressed
  zlib streams; delta compression is a v0.3+ item.
  """

  alias Exgit.Pack.{Common, Index}

  @spec build([Exgit.Object.t()]) :: binary()
  def build(objects) do
    {pack, _idx_entries} = build_entries(objects)
    pack
  end

  @doc """
  Build a pack AND its index. Returns `{pack_bytes, idx_bytes}`.
  """
  @spec build_with_index([Exgit.Object.t()]) :: {binary(), binary()}
  def build_with_index(objects) do
    {pack, entries} = build_entries(objects)
    pack_checksum = binary_part(pack, byte_size(pack) - 20, 20)
    idx = Index.write(entries, pack_checksum)
    {pack, idx}
  end

  defp build_entries(objects) do
    num_objects = length(objects)

    header = <<
      Common.pack_signature()::binary,
      Common.pack_version()::32-big,
      num_objects::32-big
    >>

    {encoded, entries, _final_offset} =
      Enum.reduce(objects, {[], [], 12}, fn obj, {bins, entries, offset} ->
        encoded = encode_object(obj)
        bin = IO.iodata_to_binary(encoded)
        crc = :erlang.crc32(bin)
        sha = Exgit.Object.sha(obj)
        {[bin | bins], [{sha, crc, offset} | entries], offset + byte_size(bin)}
      end)

    pack_body = IO.iodata_to_binary([header, Enum.reverse(encoded)])
    checksum = :crypto.hash(:sha, pack_body)
    pack = pack_body <> checksum

    {pack, Enum.reverse(entries)}
  end

  defp encode_object(object) do
    type_code = Common.type_code(Exgit.Object.type(object))
    content = Exgit.Object.encode(object) |> IO.iodata_to_binary()
    size = byte_size(content)
    type_size_header = Common.encode_type_size_varint(type_code, size)
    compressed = deflate(content)
    [type_size_header, compressed]
  end

  defp deflate(data) do
    z = :zlib.open()

    try do
      :zlib.deflateInit(z)
      compressed = :zlib.deflate(z, data, :finish)
      IO.iodata_to_binary(compressed)
    after
      # Always deflateEnd + close, even on an exception from
      # deflate/3 (OOM, port closed, etc.). Without the try/after the
      # port leaks; a long-running push-heavy service eventually
      # runs out of BEAM port slots.
      _ =
        try do
          :zlib.deflateEnd(z)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      :zlib.close(z)
    end
  end
end
