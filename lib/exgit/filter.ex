defmodule Exgit.Filter do
  @moduledoc """
  Partial-clone filter specs (git protocol v2 `filter` capability).

  Filters tell the server to omit certain objects from the packfile it
  sends. The classic use case is `{:blob, :none}` ("blobless clone"),
  which skips all blobs — an agent that only needs to list files or
  traverse history doesn't pay the cost of fetching file contents it
  will never read.

  ## Supported specs

    * `:none` — no filter. Default.
    * `{:blob, :none}` — server omits all blobs. Encoded as `"blob:none"`.
    * `{:blob, {:limit, bytes_or_string}}` — server omits blobs larger than
      the given size. `bytes_or_string` is either an integer byte count
      (`1024`) or a human-readable string (`"1m"`, `"100k"`). Encoded as
      `"blob:limit=<value>"`.
    * `{:tree, depth}` — server omits trees deeper than `depth`. Encoded
      as `"tree:<depth>"`. Depth 0 means commits only.
    * `{:raw, "<spec>"}` — escape hatch for specs we haven't modelled.
      Passed to the server verbatim.

  ## Errors

  `encode/1` validates specs up front. An invalid spec returns
  `{:error, {:invalid_filter, reason}}` rather than reaching the wire.
  """

  @type spec ::
          :none
          | {:blob, :none}
          | {:blob, {:limit, pos_integer() | String.t()}}
          | {:tree, non_neg_integer()}
          | {:raw, String.t()}

  @doc """
  Validate and encode a filter spec. Returns `:none` for `:none`,
  otherwise `{:ok, wire_string}` or `{:error, {:invalid_filter, _}}`.
  """
  @spec encode(spec()) :: :none | {:ok, String.t()} | {:error, term()}
  def encode(:none), do: :none

  def encode({:blob, :none}), do: {:ok, "blob:none"}

  def encode({:blob, {:limit, n}}) when is_integer(n) and n > 0 do
    {:ok, "blob:limit=#{n}"}
  end

  def encode({:blob, {:limit, s}}) when is_binary(s) and byte_size(s) > 0 do
    if Regex.match?(~r/^\d+[kmg]?$/i, s) do
      {:ok, "blob:limit=#{s}"}
    else
      {:error, {:invalid_filter, {:bad_blob_limit, s}}}
    end
  end

  def encode({:tree, depth}) when is_integer(depth) and depth >= 0 do
    {:ok, "tree:#{depth}"}
  end

  def encode({:raw, s}) when is_binary(s) and byte_size(s) > 0, do: {:ok, s}

  def encode(other), do: {:error, {:invalid_filter, other}}
end
