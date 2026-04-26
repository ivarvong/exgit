defmodule Exgit.PktLine.DecoderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.PktLine
  alias Exgit.PktLine.Decoder

  describe "feed/2" do
    test "single complete packet in one feed" do
      chunk = IO.iodata_to_binary(PktLine.encode("hello\n"))

      assert {:ok, %Decoder{buffer: <<>>}, [{:data, "hello\n"}]} =
               Decoder.feed(Decoder.new(), chunk)
    end

    test "multiple packets + flush in one feed" do
      chunk =
        IO.iodata_to_binary([
          PktLine.encode("one\n"),
          PktLine.encode("two\n"),
          PktLine.flush()
        ])

      assert {:ok, %Decoder{buffer: <<>>}, pkts} = Decoder.feed(Decoder.new(), chunk)
      assert pkts == [{:data, "one\n"}, {:data, "two\n"}, :flush]
    end

    test "split mid-payload" do
      bytes = IO.iodata_to_binary(PktLine.encode("hello world"))
      <<head::binary-size(8), tail::binary>> = bytes

      {:ok, d1, []} = Decoder.feed(Decoder.new(), head)
      assert d1.buffer == head

      {:ok, d2, [{:data, "hello world"}]} = Decoder.feed(d1, tail)
      assert d2.buffer == <<>>
    end

    test "split mid-header" do
      bytes = IO.iodata_to_binary(PktLine.encode("payload"))
      <<head::binary-size(2), tail::binary>> = bytes

      {:ok, d1, []} = Decoder.feed(Decoder.new(), head)
      assert d1.buffer == head

      {:ok, d2, [{:data, "payload"}]} = Decoder.feed(d1, tail)
      assert d2.buffer == <<>>
    end

    test "split exactly on packet boundary" do
      bytes =
        IO.iodata_to_binary([
          PktLine.encode("a"),
          PktLine.encode("b")
        ])

      <<first::binary-size(5), second::binary>> = bytes
      assert first == "0005a"

      {:ok, d1, [{:data, "a"}]} = Decoder.feed(Decoder.new(), first)
      assert d1.buffer == <<>>

      {:ok, d2, [{:data, "b"}]} = Decoder.feed(d1, second)
      assert d2.buffer == <<>>
    end

    test "sentinels (flush, delim, response_end) split across feeds" do
      bytes =
        IO.iodata_to_binary([
          PktLine.delim(),
          PktLine.flush(),
          PktLine.response_end()
        ])

      # Feed one byte at a time — exercises the <4-bytes-of-header path.
      {final, all_pkts} =
        Enum.reduce(:binary.bin_to_list(bytes), {Decoder.new(), []}, fn b, {d, acc} ->
          {:ok, d, pkts} = Decoder.feed(d, <<b>>)
          {d, acc ++ pkts}
        end)

      assert final.buffer == <<>>
      assert all_pkts == [:delim, :flush, :response_end]
    end

    test "malformed length returns error" do
      assert {:error, {:malformed_length, "ZZZZ"}} =
               Decoder.feed(Decoder.new(), "ZZZZpayload")
    end

    test "length below header size returns error" do
      # 0003 claims 3 bytes — less than the 4-byte header.
      assert {:error, {:malformed_length, "0003"}} =
               Decoder.feed(Decoder.new(), "0003")
    end
  end

  describe "finalize/1" do
    test "clean buffer returns :ok" do
      assert :ok = Decoder.finalize(Decoder.new())
    end

    test "trailing partial packet returns truncated error" do
      {:ok, d, []} = Decoder.feed(Decoder.new(), "0009hel")
      assert {:error, {:truncated, 7}} = Decoder.finalize(d)
    end
  end

  describe "round-trip parity with PktLine.decode_all/1" do
    property "any byte-chunking of an encoded stream yields the same packets" do
      check all(
              payloads <-
                list_of(binary(min_length: 1, max_length: 256), min_length: 1, max_length: 30),
              chunk_sizes <- list_of(integer(1..64), min_length: 1, max_length: 50)
            ) do
        encoded =
          payloads
          |> Enum.map(&PktLine.encode/1)
          |> IO.iodata_to_binary()

        expected = PktLine.decode_all(encoded)

        # Chunk the encoded bytes per chunk_sizes, looping back through
        # the size list as needed, and feed sequentially.
        {final, got} = chunk_and_feed(encoded, chunk_sizes)
        assert :ok = Decoder.finalize(final)
        assert got == expected
      end
    end
  end

  defp chunk_and_feed(bytes, sizes) do
    chunk_and_feed(bytes, sizes, sizes, Decoder.new(), [])
  end

  defp chunk_and_feed(<<>>, _, _, decoder, acc), do: {decoder, Enum.reverse(acc)}

  defp chunk_and_feed(bytes, [], original, decoder, acc),
    do: chunk_and_feed(bytes, original, original, decoder, acc)

  defp chunk_and_feed(bytes, [size | rest], original, decoder, acc) do
    n = min(size, byte_size(bytes))
    <<chunk::binary-size(n), tail::binary>> = bytes
    {:ok, decoder, pkts} = Decoder.feed(decoder, chunk)
    chunk_and_feed(tail, rest, original, decoder, Enum.reverse(pkts) ++ acc)
  end
end
