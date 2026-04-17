defmodule Exgit.Pack.InflateTrackedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exgit.Object.Blob
  alias Exgit.Pack.{Reader, Writer}

  @moduletag :property

  describe "inflater consumption is exact (P0.7)" do
    property "pack of varying-size random blobs round-trips exactly" do
      check all(
              data_sizes <- list_of(integer(0..2_048), min_length: 1, max_length: 20),
              max_runs: 30
            ) do
        blobs =
          for size <- data_sizes do
            Blob.new(:crypto.strong_rand_bytes(size))
          end

        pack = Writer.build(blobs)
        {:ok, parsed} = Reader.parse(pack)

        assert length(parsed) == length(blobs)

        for {blob, {type, sha, _content}} <- Enum.zip(blobs, parsed) do
          assert type == :blob
          assert sha == Blob.sha(blob)
        end
      end
    end

    test "empty blob in pack parses correctly" do
      blob = Blob.new(<<>>)
      pack = Writer.build([blob])

      assert {:ok, [{:blob, sha, content}]} = Reader.parse(pack)
      assert sha == Blob.sha(blob)
      assert content == <<>>
    end

    test "pack with 256 different-size blobs parses without re-scanning the whole pack" do
      # The old `find_compressed_length` tried progressively larger
      # prefixes of the REMAINING pack data for every object. On a pack
      # with N objects of average K bytes, work was O(N * log N * N*K).
      # A correct implementation is O(total_compressed_bytes).
      blobs =
        for i <- 1..256 do
          Blob.new(:crypto.strong_rand_bytes(1 + rem(i, 64)))
        end

      pack = Writer.build(blobs)
      {time_us, {:ok, parsed}} = :timer.tc(fn -> Reader.parse(pack) end)

      assert length(parsed) == 256
      # Pack is tiny (~ a few KB). Parsing must be trivially fast.
      assert time_us < 500_000,
             "256-blob small pack took #{time_us}us — inflater likely re-scanning"
    end
  end
end
