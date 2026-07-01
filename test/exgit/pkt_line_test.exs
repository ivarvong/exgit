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

    test "encodes a payload at exactly the 65516-byte max" do
      payload = :binary.copy("a", 65_516)
      # 65516 + 4 = 65520 = 0xFFF0, git's LARGE_PACKET_MAX.
      assert IO.iodata_to_binary(PktLine.encode(payload)) == "FFF0" <> payload
    end

    test "raises ArgumentError for a payload over the 65516-byte max" do
      payload = :binary.copy("a", 65_517)

      assert_raise ArgumentError, ~r/65517 bytes; max is 65516/, fn ->
        PktLine.encode(payload)
      end
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

  describe "malformed input" do
    test "non-hex length header returns an error tuple" do
      assert {:error, {:malformed_pkt_line, "ZZZZgarbage"}} =
               PktLine.decode_all("ZZZZgarbage")
    end

    test "truncated header returns an error tuple" do
      assert {:error, {:malformed_pkt_line, "00"}} = PktLine.decode_all("00")
    end

    test "truncated payload returns an error tuple" do
      # Header claims 9 bytes total but only 3 payload bytes follow.
      assert {:error, {:malformed_pkt_line, "0009hel"}} = PktLine.decode_all("0009hel")
    end

    test "a malformed tail rejects the whole stream" do
      encoded = IO.iodata_to_binary([PktLine.encode("good\n"), "ZZZZ"])
      assert {:error, {:malformed_pkt_line, "ZZZZ"}} = PktLine.decode_all(encoded)
    end

    test "decode_stream yields packets, then the error token, then halts" do
      encoded = IO.iodata_to_binary([PktLine.encode("good\n"), "ZZZZ"])

      assert [{:data, "good\n"}, {:error, {:malformed_pkt_line, "ZZZZ"}}] =
               Enum.to_list(PktLine.decode_stream(encoded))
    end

    test "error snippet is capped at 40 bytes" do
      garbage = "Z" <> :binary.copy("y", 100)
      assert {:error, {:malformed_pkt_line, snippet}} = PktLine.decode_all(garbage)
      assert byte_size(snippet) == 40
    end
  end

  describe "round-trip" do
    property "encode then decode preserves payload" do
      check all(
              payloads <-
                list_of(binary(min_length: 1, max_length: 65_000), min_length: 1, max_length: 20)
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
