defmodule Exgit.Object.Commit do
  @moduledoc """
  A git commit object.

  Commits are represented as a message plus an **ordered list of headers**.
  Preserving both the order and the verbatim content of headers is required
  for SHA stability: two commits with the same logical content but different
  header orderings are distinct git objects with distinct SHAs. This matters
  especially for signed commits — tampering with the header order would
  invalidate the `gpgsig` block.

  Convenience accessors (`tree/1`, `parents/1`, `author/1`, `committer/1`,
  `gpgsig/1`) extract well-known headers. Arbitrary headers (e.g. `encoding`,
  `mergetag`, `HG:rename`) are preserved in the `:headers` list but have no
  dedicated accessor.
  """

  alias Exgit.Object.Hex

  @enforce_keys [:headers, :message]
  defstruct [:headers, :message]

  @type header :: {name :: String.t(), value :: String.t()}
  @type t :: %__MODULE__{headers: [header()], message: String.t()}

  @spec new(keyword()) :: t()
  def new(opts) do
    tree = Keyword.fetch!(opts, :tree)
    parents = Keyword.get(opts, :parents, [])
    author = Keyword.fetch!(opts, :author)
    committer = Keyword.fetch!(opts, :committer)
    message = Keyword.fetch!(opts, :message)
    gpgsig = Keyword.get(opts, :gpgsig)

    parent_headers = Enum.map(parents, fn p -> {"parent", Hex.encode(p)} end)

    headers =
      [{"tree", Hex.encode(tree)}] ++
        parent_headers ++
        [{"author", author}, {"committer", committer}] ++
        if(gpgsig, do: [{"gpgsig", gpgsig}], else: [])

    %__MODULE__{headers: headers, message: message}
  end

  @spec tree(t()) :: binary()
  def tree(%__MODULE__{} = c), do: header!(c, "tree") |> Hex.decode!()

  @spec parents(t()) :: [binary()]
  def parents(%__MODULE__{headers: hs}) do
    for {"parent", v} <- hs, do: Hex.decode!(v)
  end

  @spec author(t()) :: String.t()
  def author(%__MODULE__{} = c), do: header!(c, "author")

  @spec committer(t()) :: String.t()
  def committer(%__MODULE__{} = c), do: header!(c, "committer")

  @spec gpgsig(t()) :: String.t() | nil
  def gpgsig(%__MODULE__{headers: hs}) do
    Enum.find_value(hs, fn
      {"gpgsig", v} -> v
      _ -> nil
    end)
  end

  defp header!(%__MODULE__{headers: hs}, name) do
    case Enum.find(hs, fn {n, _} -> n == name end) do
      {_, v} -> v
      nil -> raise KeyError, key: name
    end
  end

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{headers: headers, message: message}) do
    [
      Enum.map(headers, &encode_header/1),
      ?\n,
      message
    ]
  end

  defp encode_header({name, value}) do
    case String.split(value, "\n") do
      [single] -> [name, ?\s, single, ?\n]
      [first | rest] -> [name, ?\s, first, ?\n, Enum.map(rest, fn l -> [?\s, l, ?\n] end)]
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    case :binary.match(bytes, "\n\n") do
      {pos, 2} ->
        <<raw_headers::binary-size(pos), "\n\n", message::binary>> = bytes

        case parse_headers(raw_headers) do
          {:ok, headers} ->
            # Minimal structural validation: a commit must have tree +
            # author + committer. This catches e.g. a malformed header
            # block without being strict about order or unknown headers.
            #
            # We additionally validate that `tree` and every `parent`
            # header is a syntactically-valid 40-char hex string so that
            # accessor calls (`tree/1`, `parents/1`) are infallible.
            # Without this, a hostile remote can ship a commit with
            # `tree not-actually-hex` and DoS any downstream walk, diff,
            # or FS operation that touches the tree accessor.
            with :ok <- ensure_header(headers, "tree"),
                 :ok <- ensure_header(headers, "author"),
                 :ok <- ensure_header(headers, "committer"),
                 :ok <- ensure_hex_header(headers, "tree"),
                 :ok <- ensure_hex_headers(headers, "parent") do
              {:ok, %__MODULE__{headers: headers, message: message}}
            end

          {:error, _} = err ->
            err
        end

      :nomatch ->
        {:error, :missing_message_separator}
    end
  rescue
    e -> {:error, {:decode_failed, e}}
  end

  defp ensure_header(headers, name) do
    if Enum.any?(headers, fn {n, _} -> n == name end),
      do: :ok,
      else: {:error, {:missing_header, name}}
  end

  defp ensure_hex_header(headers, name) do
    case Enum.find(headers, fn {n, _} -> n == name end) do
      {_, v} ->
        case Hex.decode(v) do
          {:ok, _} -> :ok
          :error -> {:error, {:invalid_hex_header, name, v}}
        end

      nil ->
        :ok
    end
  end

  defp ensure_hex_headers(headers, name) do
    Enum.reduce_while(headers, :ok, fn
      {^name, v}, :ok ->
        case Hex.decode(v) do
          {:ok, _} -> {:cont, :ok}
          :error -> {:halt, {:error, {:invalid_hex_header, name, v}}}
        end

      _, :ok ->
        {:cont, :ok}
    end)
  end

  # Parse headers preserving order. Continuation lines (lines starting with
  # a space) extend the previous header's value with a leading newline.
  # A continuation line appearing before any header is an error.
  defp parse_headers(raw) do
    lines = String.split(raw, "\n")

    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case {line, acc} do
        {" " <> rest, [{name, val} | tail]} ->
          {:cont, {:ok, [{name, val <> "\n" <> rest} | tail]}}

        {" " <> _, []} ->
          {:halt, {:error, :leading_continuation}}

        {line, acc} ->
          case String.split(line, " ", parts: 2) do
            [name, val] when name != "" -> {:cont, {:ok, [{name, val} | acc]}}
            [""] -> {:halt, {:error, :malformed_header}}
            _ -> {:halt, {:error, :malformed_header}}
          end
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  @spec sha(t()) :: Exgit.Object.sha()
  def sha(%__MODULE__{} = commit), do: Exgit.Object.compute_sha("commit", encode(commit))

  @spec sha_hex(t()) :: String.t()
  def sha_hex(%__MODULE__{} = commit), do: Base.encode16(sha(commit), case: :lower)
end
