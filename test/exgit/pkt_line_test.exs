defmodule Exgit.PktLineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.PktLine

  describe "encode/1" do
    test "encodes a simple line" do
      assert IO.iodata_to_binary(PktLine.encode("hello")) == "0009hello"
    end

    test "encodes an empty payload" do
      assert IO.iodata_to_binary(PktLine.encode("")) == "0004"
    end
  end

  describe "special packets" do
    test "flush" do
      assert PktLine.flush() == "0000"
    end

    test "delim" do
      assert PktLine.delim() == "0001"
    end

    test "response_end" do
      assert PktLine.response_end() == "0002"
    end
  end

  describe "decode_stream/1" do
    test "decodes a sequence of packets" do
      encoded =
        IO.iodata_to_binary([
          PktLine.encode("hello\n"),
          PktLine.encode("world\n"),
          PktLine.flush()
        ])

      assert PktLine.decode_all(encoded) == [
               {:data, "hello\n"},
               {:data, "world\n"},
               :flush
             ]
    end

    test "decodes delim and response_end" do
      encoded =
        IO.iodata_to_binary([
          PktLine.encode("data\n"),
          PktLine.delim(),
          PktLine.encode("more\n"),
          PktLine.response_end()
        ])

      assert PktLine.decode_all(encoded) == [
               {:data, "data\n"},
               :delim,
               {:data, "more\n"},
               :response_end
             ]
    end
  end

  describe "round-trip" do
    property "encode then decode preserves payload" do
      check all(
              payloads <-
                list_of(binary(min_length: 1, max_length: 65000), min_length: 1, max_length: 20)
            ) do
        encoded =
          payloads
          |> Enum.map(&PktLine.encode/1)
          |> IO.iodata_to_binary()

        decoded =
          PktLine.decode_all(encoded)
          |> Enum.map(fn {:data, d} -> d end)

        assert decoded == payloads
      end
    end
  end
end
