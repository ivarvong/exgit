defmodule Exgit.LFS do
  @moduledoc """
  Git LFS (Large File Storage) pointer detection.

  Git LFS replaces large binary blobs in the object database with
  small text "pointer" files of the form:

      version https://git-lfs.github.com/spec/v1
      oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      size 12345

  The actual content lives on an LFS server and is fetched via a
  separate protocol (batch API over HTTPS). An agent reading the
  blob through normal git-object APIs sees the ~130-byte pointer
  text, not the file contents — a silent correctness cliff if the
  agent doesn't know to check.

  `Exgit.FS.read_path/4` with `resolve_lfs_pointers: true` uses
  `parse/1` here to surface detected pointers as a structured
  `{:lfs_pointer, info}` tuple instead of returning the pointer
  text as if it were content.

  ## Strictness

  `parse/1` matches `git lfs pointer --check` behavior:

    * Input must be ≤ `@max_pointer_bytes` (1024 bytes). Real LFS
      pointers are ~130 bytes; the cap rejects regular blobs that
      happen to start with "version https://...".
    * First line must be exactly `version https://git-lfs.github.com/spec/v1\\n`.
    * Subsequent lines must be `<key> <value>\\n` pairs, keys in
      ASCII-sorted order, values non-empty.
    * `oid` and `size` are required; `oid` must match `sha256:<64 hex>`
      and `size` must be a non-negative decimal integer.
    * Unknown keys are permitted only if they match `ext-N-<name>`
      where N is a decimal. Unknown non-ext keys cause rejection.
    * Input must end with `\\n`.

  The tight matching keeps false positives near zero — a regular
  text blob that coincidentally starts with the version line still
  has to satisfy every other constraint.
  """

  @version_line "version https://git-lfs.github.com/spec/v1\n"
  @max_pointer_bytes 1024

  @type pointer_info :: %{
          oid: String.t(),
          size: non_neg_integer(),
          raw: binary()
        }

  @doc """
  Parse `data` as a git-lfs pointer file.

  Returns `{:ok, %{oid, size, raw}}` on a valid pointer, or
  `{:error, reason}` on any rejection.

  The `raw` field is the original bytes unchanged — callers that
  want to re-emit the pointer (e.g. to pass through to a layer
  that knows how to fetch from the LFS server) can use it
  without having to reserialize.

  ## Examples

      iex> ptr = \"\"\"
      ...> version https://git-lfs.github.com/spec/v1
      ...> oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
      ...> size 12345
      ...> \"\"\"
      iex> {:ok, info} = Exgit.LFS.parse(ptr)
      iex> info.size
      12345
      iex> info.oid
      "sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"

      iex> Exgit.LFS.parse("not an lfs pointer")
      {:error, :not_lfs_pointer}
  """
  @spec parse(binary()) :: {:ok, pointer_info()} | {:error, term()}
  def parse(data) when is_binary(data) do
    cond do
      byte_size(data) > @max_pointer_bytes ->
        {:error, :too_large_for_pointer}

      not String.ends_with?(data, "\n") ->
        {:error, :missing_trailing_newline}

      not String.starts_with?(data, @version_line) ->
        {:error, :not_lfs_pointer}

      true ->
        rest = binary_part(data, byte_size(@version_line), byte_size(data) - byte_size(@version_line))
        parse_body(rest, data)
    end
  end

  def parse(_), do: {:error, :not_binary}

  @doc """
  Predicate form of `parse/1`. Returns `true` iff `data` is a
  valid LFS pointer.
  """
  @spec pointer?(binary()) :: boolean()
  def pointer?(data) when is_binary(data) do
    match?({:ok, _}, parse(data))
  end

  def pointer?(_), do: false

  # --- Internal ---

  defp parse_body(body, raw) do
    with {:ok, pairs} <- split_lines(body),
         :ok <- check_sorted(pairs),
         :ok <- check_no_duplicates(pairs),
         {:ok, oid} <- fetch_required(pairs, "oid"),
         :ok <- validate_oid(oid),
         {:ok, size_str} <- fetch_required(pairs, "size"),
         {:ok, size} <- parse_size(size_str),
         :ok <- validate_extra_keys(pairs) do
      {:ok, %{oid: oid, size: size, raw: raw}}
    end
  end

  # Each line must be exactly "<key> <value>\n" with one space
  # separator and a non-empty value. Returns the key/value pairs
  # in the order they appeared.
  defp split_lines(body) do
    lines = :binary.split(body, "\n", [:global])

    # After a trailing "\n", :binary.split emits an empty tail element.
    # Reject any other empty line as a malformed pointer.
    case List.last(lines) do
      "" ->
        data_lines = Enum.drop(lines, -1)

        Enum.reduce_while(data_lines, {:ok, []}, fn line, {:ok, acc} ->
          case parse_line(line) do
            {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          err -> err
        end

      _ ->
        {:error, :missing_trailing_newline}
    end
  end

  defp parse_line(""), do: {:error, :empty_line}

  defp parse_line(line) do
    case :binary.split(line, " ") do
      [key, value] when key != "" and value != "" ->
        # Keys use lowercase ASCII plus digits and hyphens per the
        # spec; reject anything that isn't tame, which also rejects
        # lines containing extra spaces.
        if valid_key?(key) and not String.contains?(value, " ") do
          {:ok, {key, value}}
        else
          {:error, {:invalid_line, line}}
        end

      _ ->
        {:error, {:invalid_line, line}}
    end
  end

  defp valid_key?(key) do
    Regex.match?(~r/\A[a-z0-9][a-z0-9\-]*\z/, key)
  end

  defp check_sorted(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.sort(keys) do
      :ok
    else
      {:error, :keys_not_sorted}
    end
  end

  defp check_no_duplicates(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :duplicate_keys}
    end
  end

  defp fetch_required(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, value} -> {:ok, value}
      nil -> {:error, {:missing_key, key}}
    end
  end

  defp validate_oid("sha256:" <> hex) do
    if byte_size(hex) == 64 and lower_hex?(hex) do
      :ok
    else
      {:error, :invalid_oid}
    end
  end

  defp validate_oid(_), do: {:error, :invalid_oid_scheme}

  defp lower_hex?(bin) do
    # Avoids allocating a Regex; lowercase-hex is a very tight hot
    # predicate for agents scanning many blobs.
    lower_hex_loop(bin)
  end

  defp lower_hex_loop(<<>>), do: true

  defp lower_hex_loop(<<c, rest::binary>>)
       when c in ?0..?9
       when c in ?a..?f,
       do: lower_hex_loop(rest)

  defp lower_hex_loop(_), do: false

  defp parse_size(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_size, s}}
    end
  end

  # Any key other than "oid" / "size" must be of the form
  # "ext-N-<name>" where N is a decimal integer. Git-LFS permits
  # extension keys; anything else signals a malformed pointer.
  defp validate_extra_keys(pairs) do
    extras =
      pairs
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(&1 in ["oid", "size"]))

    Enum.reduce_while(extras, :ok, fn key, :ok ->
      if ext_key?(key) do
        {:cont, :ok}
      else
        {:halt, {:error, {:unknown_key, key}}}
      end
    end)
  end

  defp ext_key?("ext-" <> rest) do
    case :binary.split(rest, "-") do
      [num, name] when name != "" ->
        case Integer.parse(num) do
          {n, ""} when n >= 0 -> valid_key?(name)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp ext_key?(_), do: false
end
