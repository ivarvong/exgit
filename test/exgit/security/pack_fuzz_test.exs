defmodule Exgit.Security.PackFuzzTest do
  @moduledoc """
  Adversarial pack fuzzing: no decoder call on untrusted bytes may
  raise an Elixir exception. Every path must surface `{:error, _}`.

  This is a CI-gating test. If a run here raises, the library can be
  crashed by a hostile server; that's a P0.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  @moduletag :property

  alias Exgit.Pack.{Common, Delta, Reader}

  describe "Pack.Reader.parse/2 (untrusted input)" do
    property "never raises on random bytes" do
      check all(bytes <- binary(min_length: 0, max_length: 2048), max_runs: 1_000) do
        assert no_raise(fn -> Reader.parse(bytes) end)
      end
    end

    property "never raises on PACK-prefixed garbage" do
      check all(
              garbage <- binary(max_length: 2048),
              version <- integer(1..5),
              count <- integer(0..100_000),
              max_runs: 500
            ) do
        input = "PACK" <> <<version::32-big, count::32-big>> <> garbage
        assert no_raise(fn -> Reader.parse(input) end)
      end
    end

    property "rejects packs larger than :max_pack_bytes" do
      # Construct a pack that would be valid if the limit allowed it.
      check all(extra <- integer(0..128), max_runs: 50) do
        oversize = :crypto.strong_rand_bytes(256 + extra)

        assert {:error, {:pack_too_large, _, _}} =
                 Reader.parse(oversize, max_pack_bytes: 64)
      end
    end

    property "rejects packs claiming more objects than :max_objects" do
      check all(count <- integer(1_000_001..10_000_000), max_runs: 20) do
        header = "PACK" <> <<2::32-big, count::32-big>>
        # Append enough bytes for the header verifier not to trip first.
        body = :crypto.strong_rand_bytes(64)
        trailer = :crypto.hash(:sha, header <> body)
        pack = header <> body <> trailer

        assert {:error, _} = Reader.parse(pack, max_objects: 1_000_000)
      end
    end
  end

  describe "Pack.Reader.parse_at/3 (single-object lookup)" do
    property "never raises on random bytes + random offset" do
      check all(
              bytes <- binary(max_length: 4096),
              offset <- integer(0..8192),
              max_runs: 500
            ) do
        assert no_raise(fn -> Reader.parse_at(bytes, offset) end)
      end
    end
  end

  describe "Pack.Delta.apply/2 (untrusted delta)" do
    property "never raises on random delta bytes + random base" do
      check all(
              base <- binary(min_length: 0, max_length: 1024),
              delta <- binary(min_length: 0, max_length: 512),
              max_runs: 1_000
            ) do
        assert no_raise(fn -> Delta.apply(base, delta) end)
      end
    end

    test "out-of-bounds copy returns {:error, _} instead of raising" do
      # Hand-crafted delta: "copy 1000 bytes at offset 0" against a
      # 5-byte base. Older impl raised ArgumentError via binary_part.
      base = "hello"

      # Delta format: base_size, result_size, [copy-or-insert ops].
      # Copy op: 0x80 | bits flags, then little-endian offset + size bytes.
      # 0x80 alone means "offset 0, size 0" — we add 0x30 to include
      # one byte of offset and one byte of size.
      copy_op = <<bor(bor(0x80, 0x10), 0x20), 0x00, 0xFF>>

      delta =
        encode_size(byte_size(base)) <>
          encode_size(1000) <>
          copy_op

      assert {:error, _} = Delta.apply(base, delta)
    end

    test "insert of N bytes where payload is < N returns {:error, _}" do
      # Insert op: opcode byte 1..127 means "insert N bytes inline".
      # We set N=100 but provide only 5 bytes.
      delta = encode_size(0) <> encode_size(100) <> <<100>> <> "hello"

      assert {:error, _} = Delta.apply("", delta)
    end
  end

  describe "Pack.Common decoders" do
    property "decode_type_size_varint never raises" do
      check all(bytes <- binary(min_length: 0, max_length: 16), max_runs: 500) do
        assert no_raise(fn -> Common.decode_type_size_varint(bytes) end)
      end
    end

    property "decode_ofs_varint never raises" do
      check all(bytes <- binary(min_length: 0, max_length: 16), max_runs: 500) do
        assert no_raise(fn -> Common.decode_ofs_varint(bytes) end)
      end
    end
  end

  # Helpers

  defp no_raise(fun) do
    case fun.() do
      {:ok, _} -> true
      {:ok, _, _} -> true
      {:error, _} -> true
      result when is_tuple(result) -> true
      result when is_list(result) -> true
      result when is_binary(result) -> true
      result when is_atom(result) -> true
      _other -> true
    end
  rescue
    e ->
      flunk("decoder raised: #{inspect(e)}\n" <> Exception.format_stacktrace())
  catch
    kind, value ->
      flunk("decoder threw #{kind}: #{inspect(value)}")
  end

  # git-style varint size encoding (little-endian continuation).
  defp encode_size(n) when n < 128, do: <<n>>

  defp encode_size(n) do
    <<bor(band(n, 0x7F), 0x80)>> <> encode_size(bsr(n, 7))
  end
end
