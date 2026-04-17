defmodule Exgit.Pack.Writer do
  alias Exgit.Pack.Common

  @spec build([Exgit.Object.t()]) :: binary()
  def build(objects) do
    num_objects = length(objects)

    header = <<
      Common.pack_signature()::binary,
      Common.pack_version()::32-big,
      num_objects::32-big
    >>

    entries = Enum.map(objects, &encode_object/1)
    pack_data = IO.iodata_to_binary([header | entries])
    checksum = :crypto.hash(:sha, pack_data)
    pack_data <> checksum
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
    :zlib.deflateInit(z)
    compressed = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(compressed)
  end
end
