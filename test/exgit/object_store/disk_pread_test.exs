defmodule Exgit.ObjectStore.DiskPreadTest do
  @moduledoc """
  A2: ObjectStore.Disk pack lookups must use file:pread/3 with the
  idx offset, not read the entire pack into memory. Validated by a
  memory-watermark check against a big synthetic pack.
  """

  use ExUnit.Case, async: false

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore
  alias Exgit.Pack.{Index, Writer}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "exgit_pread_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "objects/pack"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, store: ObjectStore.Disk.new(root)}
  end

  @tag :slow
  @tag timeout: 180_000
  test "lookup latency is independent of pack size (pread behavior)", %{root: root, store: store} do
    # Build two packs: small (~200KB) and large (~9MB). A properly-preading
    # store serves single-object lookups in roughly the same time
    # regardless of pack size. A read-entire-pack store's latency scales
    # with pack size.
    small_blobs = for i <- 1..20, do: Blob.new("small_#{i}_" <> :crypto.strong_rand_bytes(2_048))

    # Keep "large" meaningfully bigger than small while staying within
    # CI budget. Ratio is what matters.
    large_blobs =
      for i <- 1..80, do: Blob.new("large_#{i}_" <> :crypto.strong_rand_bytes(20_000))

    small_time = time_sample_lookup(root, store, "small", small_blobs)
    large_time = time_sample_lookup(root, store, "large", large_blobs)

    # Ratio should be near 1.0 for pread; unbounded for read-whole-pack.
    ratio = large_time / max(small_time, 1)

    assert ratio < 4.0,
           "large-pack lookup is #{Float.round(ratio, 2)}× slower than small-pack " <>
             "(#{large_time}us vs #{small_time}us) — store likely reads whole pack per lookup"
  end

  defp time_sample_lookup(root, store, tag, blobs) do
    pack = Writer.build(blobs)

    pack_path = Path.join(root, "objects/pack/pack-#{tag}.pack")
    idx_path = Path.join(root, "objects/pack/pack-#{tag}.idx")
    File.write!(pack_path, pack)

    entries = build_entries(pack, blobs)
    checksum = binary_part(pack, byte_size(pack) - 20, 20)
    File.write!(idx_path, Index.write(entries, checksum))

    # Warm
    {:ok, _} = ObjectStore.get(store, Blob.sha(hd(blobs)))

    sample = Enum.take_random(blobs, min(20, length(blobs)))

    {t, _} =
      :timer.tc(fn ->
        for b <- sample do
          {:ok, _} = ObjectStore.get(store, Blob.sha(b))
        end
      end)

    div(t, length(sample))
  end

  @tag :slow
  @tag timeout: 180_000
  test "single-object lookup into a large pack uses bounded memory", %{root: root, store: store} do
    # Build a pack with a few dozen reasonably-sized blobs so the total
    # pack is much larger than any individual object but fixture
    # generation stays fast on shared CI runners.
    n = 80
    payload_size = 16 * 1024

    blobs =
      for i <- 1..n do
        Blob.new("blob_#{i}_" <> :crypto.strong_rand_bytes(payload_size))
      end

    pack = Writer.build(blobs)
    pack_size = byte_size(pack)

    pack_path = Path.join(root, "objects/pack/pack-big.pack")
    idx_path = Path.join(root, "objects/pack/pack-big.idx")
    File.write!(pack_path, pack)

    entries = build_entries(pack, blobs)
    pack_checksum = binary_part(pack, pack_size - 20, 20)
    File.write!(idx_path, Index.write(entries, pack_checksum))

    # Warm.
    {:ok, _} = ObjectStore.get(store, Blob.sha(hd(blobs)))

    # Measure BEAM binary-heap usage while looking up 50 random objects.
    sample = Enum.take_random(blobs, 50)

    before = total_binary_memory()

    for blob <- sample do
      {:ok, %Blob{}} = ObjectStore.get(store, Blob.sha(blob))
    end

    after_ = total_binary_memory()
    delta = after_ - before

    # If the store reads the whole pack per lookup, delta grows to
    # ~50 * pack_size. Proper pread gives ~50 * payload_size. We
    # assert 3× payload margin.
    bound = 50 * payload_size * 3

    assert delta < bound,
           "binary heap grew by #{delta} bytes over 50 lookups on a #{pack_size}-byte pack " <>
             "(bound: #{bound}). pread is likely not in effect."
  end

  defp total_binary_memory do
    :erlang.memory(:binary)
  end

  defp build_entries(pack, blobs) do
    {entries, _} =
      Enum.reduce(blobs, {[], 12}, fn blob, {acc, offset} ->
        {entry, next} = describe_entry(pack, offset, blob)
        {[entry | acc], next}
      end)

    Enum.reverse(entries)
  end

  defp describe_entry(pack, offset, blob) do
    <<_::binary-size(offset), from_here::binary>> = pack
    {_type_code, _size, after_header} = Exgit.Pack.Common.decode_type_size_varint(from_here)
    header_len = byte_size(from_here) - byte_size(after_header)

    compressed_len = find_zlib_length(after_header)
    total_len = header_len + compressed_len

    obj_bytes = binary_part(pack, offset, total_len)
    crc = :erlang.crc32(obj_bytes)
    {{Blob.sha(blob), crc, offset}, offset + total_len}
  end

  defp find_zlib_length(data), do: find_zlib_length(data, 2)

  defp find_zlib_length(data, n) when n > byte_size(data), do: byte_size(data)

  defp find_zlib_length(data, n) do
    try do
      :zlib.uncompress(binary_part(data, 0, n))
      n
    rescue
      _ -> find_zlib_length(data, n + 1)
    end
  end
end
