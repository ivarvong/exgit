defmodule Exgit.Pack.ReaderLimitsTest do
  @moduledoc """
  Regression for review findings #11/#35: the pack parser must cap
  total resolved-object bytes, not just per-object or per-pack bytes.
  A hostile pack whose compressed size fits under `:max_pack_bytes`
  (2 GiB default) can still expand to many GiB of resolved state
  unless we bound the total.
  """

  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.Pack.{Reader, Writer}

  test "rejects when resolved-bytes cap is exceeded" do
    # Build a legitimate pack of five small blobs.
    blobs = for i <- 1..5, do: Blob.new("blob-content-#{i}")
    pack = Writer.build(blobs)

    # With a cap smaller than any single blob's content, the second
    # object's accumulation should trip the limit.
    #
    # First blob is "blob-content-1" = 14 bytes. Set cap to 20 so we
    # can fit one but not two.
    assert {:error, {:resolved_too_large, _n, 20}} =
             Reader.parse(pack, max_resolved_bytes: 20)
  end

  test "default cap permits typical packs" do
    blobs = for i <- 1..10, do: Blob.new("blob-#{i}")
    pack = Writer.build(blobs)

    assert {:ok, parsed} = Reader.parse(pack)
    assert length(parsed) == 10
  end

  # History lesson: we once defaulted :max_resolved_bytes to 500
  # MiB, figuring "any legitimate pack fits." Then
  # anomalyco/opencode's partial-clone pack resolved to ~524 MB
  # and tripped the cap. The new default is 2 GiB (matches
  # :max_pack_bytes). This test asserts that a 600 MB aggregate
  # payload parses under the default :max_resolved_bytes.
  #
  # We split into 100 × 6 MB blobs rather than one 600 MB blob
  # because `:max_object_bytes` (100 MiB) is a separate cap — a
  # single-blob test would trip per-object, not total-resolved.
  # The aggregate pattern matches real repos (many smaller blobs)
  # and is what the resolved-bytes cap actually protects.
  #
  # Tagged `:slow` because building a 600 MB pack takes seconds.
  @tag :slow
  test "default cap admits a 600 MiB legitimate pack (regression)" do
    chunk = :binary.copy("x", 6 * 1024 * 1024)
    blobs = for i <- 1..100, do: Blob.new(<<i::32, chunk::binary>>)
    pack = Writer.build(blobs)

    assert {:ok, parsed} = Reader.parse(pack)
    assert length(parsed) == 100
  end
end
