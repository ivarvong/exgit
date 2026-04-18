defmodule Exgit.Object.Tree do
  @moduledoc """
  A git tree object.

  `decode/1` is **byte-exact**: it preserves the mode string verbatim so that
  `decode |> encode` reproduces the original tree bytes (and thus the same
  SHA). Historical git repositories occasionally contain legacy modes such
  as `100664`; normalizing those during decode would silently change the
  tree's SHA and corrupt verification.

  `new/1` applies git's canonical ordering (dirs sort as if they had a
  trailing `/`) and — by default — normalizes regular file modes via
  `canonical_mode/1`. Pass `strict: true` to error on unknown modes
  instead of silently coercing, or build the struct directly for a
  raw, unvalidated tree.

  > #### Round-trip note {: .warning}
  >
  > `Tree.new(decoded.entries)` is NOT always equivalent to `decoded` —
  > `new/1` canonicalizes modes, so a decoded tree with legacy `100664`
  > mode will have its mode rewritten by `new/1` and its SHA will
  > change. If you need byte-exact round-trip, preserve the decoded
  > struct and don't pass it through `new/1`.

  ## Path traversal

  `decode/1` validates each entry's name against the rules in `Exgit.RefName`
  for path components — rejecting `/`, `..`, `.`, empty names, and
  case-insensitive `.git`/`.gitmodules` entries. Hostile trees from a
  pack never reach a materialize/checkout/write path.
  """

  import Bitwise, only: [band: 2]

  @enforce_keys [:entries]
  defstruct [:entries]

  @type mode :: String.t()
  @type entry :: {mode(), name :: String.t(), sha :: binary()}
  @type t :: %__MODULE__{entries: [entry()]}

  @doc """
  Build a canonical tree from a list of `{mode, name, sha}` entries.

  Options:

    * `:strict` — when `true`, reject unknown modes with a
      `:invalid_mode` error. Default: `false` (unknown modes are
      silently coerced to `100644` / `100755` based on the executable
      bit).
  """
  @spec new([entry()], keyword()) :: t()
  def new(entries, opts \\ []) when is_list(entries) do
    strict? = Keyword.get(opts, :strict, false)

    normalized =
      Enum.map(entries, fn {mode, name, sha} ->
        {canonical_mode(mode, strict?), name, sha}
      end)

    %__MODULE__{entries: Enum.sort_by(normalized, &sort_key/1)}
  end

  # Git sorts tree entries as if directories had a trailing "/".
  # This ensures "foo" (dir) sorts after "foo.c" (file) but before "foo0".
  defp sort_key({mode, name, _sha}) do
    if mode == "40000", do: name <> "/", else: name
  end

  @doc """
  Normalize a file mode to one of the canonical git file modes. Used by
  `new/1` but NOT by `decode/1`. Unknown modes are returned unchanged
  by the one-arg form; the two-arg form with `strict: true` raises
  on unknown input.
  """
  @spec canonical_mode(String.t()) :: String.t()
  def canonical_mode(mode), do: canonical_mode(mode, false)

  @spec canonical_mode(String.t(), boolean()) :: String.t() | no_return()
  def canonical_mode("40000", _strict), do: "40000"
  def canonical_mode("160000", _strict), do: "160000"
  def canonical_mode("120000", _strict), do: "120000"
  def canonical_mode("100644", _strict), do: "100644"
  def canonical_mode("100755", _strict), do: "100755"

  def canonical_mode(mode, strict) when is_binary(mode) do
    # Parse as octal (git modes are always octal strings).
    case Integer.parse(mode, 8) do
      {n, ""} when not strict ->
        if band(n, 0o111) != 0, do: "100755", else: "100644"

      {_n, ""} when strict ->
        raise ArgumentError, "invalid git tree mode: #{inspect(mode)}"

      _ when strict ->
        raise ArgumentError, "invalid git tree mode: #{inspect(mode)}"

      _ ->
        mode
    end
  end

  @spec encode(t()) :: iolist()
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
         <<sha::binary-size(20), rest::binary>> <- rest,
         :ok <- validate_entry_name(name) do
      decode_entries(rest, [{mode, name, sha} | acc])
    else
      {:error, _} = err -> err
      _ -> {:error, :malformed_tree_entry}
    end
  end

  # Reject tree-entry names that would enable path traversal or
  # case-folding attacks against a checkout / materialize / FS.write
  # target. Matches git's own `fsck` rules (see `fsck.c`
  # `verify_path`).
  #
  #   - empty names
  #   - `.` and `..` components
  #   - names containing `/` (would flatten a nested path into one entry)
  #   - names starting with `/` (absolute-path write escape)
  #   - NUL bytes (already impossible because NUL is the terminator,
  #     but assert it for defense-in-depth)
  #   - `.git` in any case — a hostile tree that carries `.GIT/config`
  #     on a case-insensitive filesystem overwrites the real repo
  #     config (CVE-2014-9390 / 2014-9390-class)
  #   - `.gitmodules` in any case — URL-injection vector for submodule
  #     handling if/when we add submodules
  #
  # Hostile trees are rejected at decode time; they never reach
  # `FS.write_path`, a checkout, or `insert_blob_into_tree`.
  defp validate_entry_name(""), do: {:error, :tree_entry_name_empty}
  defp validate_entry_name("."), do: {:error, :tree_entry_name_dot}
  defp validate_entry_name(".."), do: {:error, :tree_entry_name_dotdot}

  defp validate_entry_name(name) when is_binary(name) do
    cond do
      String.contains?(name, "/") ->
        {:error, {:tree_entry_name_contains_slash, name}}

      String.contains?(name, <<0>>) ->
        {:error, {:tree_entry_name_contains_nul, name}}

      dangerous_dotgit?(name) ->
        {:error, {:tree_entry_name_reserved, name}}

      true ->
        :ok
    end
  end

  # Any component that lowercases to `.git` or `.gitmodules` is rejected.
  # Matches git's own case-insensitive reservation even on case-sensitive
  # filesystems, because a repository cloned to a case-insensitive FS
  # (macOS default, Windows) would otherwise be vulnerable.
  defp dangerous_dotgit?(name) do
    lower = String.downcase(name)
    lower == ".git" or lower == ".gitmodules"
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
