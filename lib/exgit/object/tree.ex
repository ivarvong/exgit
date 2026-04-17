defmodule Exgit.Object.Tree do
  @moduledoc """
  A git tree object.

  `decode/1` is **byte-exact**: it preserves the mode string verbatim so that
  `decode |> encode` reproduces the original tree bytes (and thus the same
  SHA). Historical git repositories occasionally contain legacy modes such
  as `100664`; normalizing those during decode would silently change the
  tree's SHA and corrupt verification.

  `new/1` applies git's canonical ordering (dirs sort as if they had a
  trailing `/`) and normalizes regular file modes via `canonical_mode/1`.
  If you want a raw, unvalidated tree, build the struct directly.
  """

  @enforce_keys [:entries]
  defstruct [:entries]

  @type mode :: String.t()
  @type entry :: {mode(), name :: String.t(), sha :: binary()}
  @type t :: %__MODULE__{entries: [entry()]}

  @spec new([entry()]) :: t()
  def new(entries) when is_list(entries) do
    normalized =
      Enum.map(entries, fn {mode, name, sha} -> {canonical_mode(mode), name, sha} end)

    %__MODULE__{entries: Enum.sort_by(normalized, &sort_key/1)}
  end

  # Git sorts tree entries as if directories had a trailing "/".
  # This ensures "foo" (dir) sorts after "foo.c" (file) but before "foo0".
  defp sort_key({mode, name, _sha}) do
    if mode == "40000", do: name <> "/", else: name
  end

  @doc """
  Normalize a file mode to one of the canonical git file modes. Used by
  `new/1` but NOT by `decode/1`. Unknown modes are returned unchanged.
  """
  @spec canonical_mode(String.t()) :: String.t()
  def canonical_mode("40000"), do: "40000"
  def canonical_mode("160000"), do: "160000"
  def canonical_mode("120000"), do: "120000"
  def canonical_mode("100644"), do: "100644"
  def canonical_mode("100755"), do: "100755"

  def canonical_mode(mode) when is_binary(mode) do
    # Parse as octal (git modes are always octal strings).
    case Integer.parse(mode, 8) do
      {n, ""} ->
        if Bitwise.band(n, 0o111) != 0, do: "100755", else: "100644"

      _ ->
        mode
    end
  end

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{entries: entries}) do
    Enum.map(entries, fn {mode, name, sha} ->
      [mode, ?\s, name, 0, sha]
    end)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    case decode_entries(bytes, []) do
      {:ok, entries} -> {:ok, %__MODULE__{entries: entries}}
      {:error, _} = err -> err
    end
  end

  defp decode_entries(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_entries(data, acc) do
    with {:ok, mode, rest} <- take_until(data, ?\s),
         {:ok, name, rest} <- take_until(rest, 0),
         <<sha::binary-size(20), rest::binary>> <- rest do
      decode_entries(rest, [{mode, name, sha} | acc])
    else
      _ -> {:error, :malformed_tree_entry}
    end
  end

  defp take_until(data, byte) do
    case :binary.match(data, <<byte>>) do
      {pos, 1} ->
        <<before::binary-size(pos), _::8, rest::binary>> = data
        {:ok, before, rest}

      :nomatch ->
        :error
    end
  end

  @spec sha(t()) :: Exgit.Object.sha()
  def sha(%__MODULE__{} = tree) do
    Exgit.Object.compute_sha("tree", encode(tree))
  end

  @spec sha_hex(t()) :: String.t()
  def sha_hex(%__MODULE__{} = tree), do: Base.encode16(sha(tree), case: :lower)
end
