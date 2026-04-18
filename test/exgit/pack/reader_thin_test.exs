defmodule Exgit.Pack.ReaderThinTest do
  use ExUnit.Case, async: true

  alias Exgit.Object.Blob
  alias Exgit.ObjectStore
  alias Exgit.Pack.Reader
  alias Exgit.Test.PackBuilder

  describe "thin pack resolution via object store (P0.9)" do
    test "REF_DELTA whose base lives in the object store resolves without raising" do
      # Put a blob into a memory store. This is the "thin pack base".
      base_blob = Blob.new("hello base content\n")
      base_content = Blob.encode(base_blob) |> IO.iodata_to_binary()
      base_sha = Blob.sha(base_blob)

      store = ObjectStore.Memory.new()
      {:ok, ^base_sha, store} = ObjectStore.put(store, base_blob)

      # Result blob: a different content, but shipped as a REF_DELTA whose
      # base is the stored blob.
      result_blob = Blob.new("hello derived content\n")
      result_content = Blob.encode(result_blob) |> IO.iodata_to_binary()

      pack =
        PackBuilder.build([
          {:ref_delta, base_sha, base_content, result_content}
        ])

      # The whole point: this must resolve from the object store, not raise
      # UndefinedFunctionError on store.__struct__.get/2.
      assert {:ok, [{:blob, sha, content}]} = Reader.parse(pack, object_store: store)
      assert sha == Blob.sha(result_blob)
      assert content == result_content
    end

    test "REF_DELTA with no matching base in store returns {:error, _} (not a raise)" do
      missing_sha = :binary.copy(<<0xAA>>, 20)
      store = ObjectStore.Memory.new()

      # We still need a valid encoded delta — give it a plausible base.
      base_content = "whatever"
      result_content = "result"

      pack =
        PackBuilder.build([
          {:ref_delta, missing_sha, base_content, result_content}
        ])

      assert {:error, {:unresolved_ref_delta, ^missing_sha}} =
               Reader.parse(pack, object_store: store)
    end
  end
end
