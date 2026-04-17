defmodule Exgit.Object do
  @type t ::
          Exgit.Object.Blob.t()
          | Exgit.Object.Tree.t()
          | Exgit.Object.Commit.t()
          | Exgit.Object.Tag.t()
  @type object_type :: :blob | :tree | :commit | :tag
  @type sha :: <<_::160>>

  @spec decode(object_type(), binary()) :: {:ok, t()} | {:error, term()}
  def decode(:blob, bytes), do: Exgit.Object.Blob.decode(bytes)
  def decode(:tree, bytes), do: Exgit.Object.Tree.decode(bytes)
  def decode(:commit, bytes), do: Exgit.Object.Commit.decode(bytes)
  def decode(:tag, bytes), do: Exgit.Object.Tag.decode(bytes)

  @spec encode(t()) :: iodata()
  def encode(%Exgit.Object.Blob{} = obj), do: Exgit.Object.Blob.encode(obj)
  def encode(%Exgit.Object.Tree{} = obj), do: Exgit.Object.Tree.encode(obj)
  def encode(%Exgit.Object.Commit{} = obj), do: Exgit.Object.Commit.encode(obj)
  def encode(%Exgit.Object.Tag{} = obj), do: Exgit.Object.Tag.encode(obj)

  @spec sha(t()) :: sha()
  def sha(%Exgit.Object.Blob{} = obj), do: Exgit.Object.Blob.sha(obj)
  def sha(%Exgit.Object.Tree{} = obj), do: Exgit.Object.Tree.sha(obj)
  def sha(%Exgit.Object.Commit{} = obj), do: Exgit.Object.Commit.sha(obj)
  def sha(%Exgit.Object.Tag{} = obj), do: Exgit.Object.Tag.sha(obj)

  @spec type(t()) :: object_type()
  def type(%Exgit.Object.Blob{}), do: :blob
  def type(%Exgit.Object.Tree{}), do: :tree
  def type(%Exgit.Object.Commit{}), do: :commit
  def type(%Exgit.Object.Tag{}), do: :tag

  @spec type_string(t()) :: String.t()
  def type_string(%Exgit.Object.Blob{}), do: "blob"
  def type_string(%Exgit.Object.Tree{}), do: "tree"
  def type_string(%Exgit.Object.Commit{}), do: "commit"
  def type_string(%Exgit.Object.Tag{}), do: "tag"

  @doc false
  @spec header(String.t(), iodata()) :: iodata()
  def header(type_str, content) do
    size = IO.iodata_length(content)
    [type_str, ?\s, Integer.to_string(size), 0]
  end

  @doc false
  @spec compute_sha(String.t(), iodata()) :: sha()
  def compute_sha(type_str, content) do
    # Incrementally hash without allocating a large intermediate binary.
    # For a 1GB blob the previous implementation would allocate a 1GB
    # binary as the SHA input; this one streams chunks through the
    # digest context.
    ctx = :crypto.hash_init(:sha)

    ctx
    |> :crypto.hash_update(IO.iodata_to_binary(header(type_str, content)))
    |> hash_update_iodata(content)
    |> :crypto.hash_final()
  end

  # Walk iodata and feed each binary chunk into the hash context without
  # materializing the full concatenation.
  defp hash_update_iodata(ctx, bin) when is_binary(bin),
    do: :crypto.hash_update(ctx, bin)

  defp hash_update_iodata(ctx, int) when is_integer(int) and int in 0..255,
    do: :crypto.hash_update(ctx, <<int>>)

  defp hash_update_iodata(ctx, list) when is_list(list) do
    Enum.reduce(list, ctx, fn elem, acc -> hash_update_iodata(acc, elem) end)
  end
end
