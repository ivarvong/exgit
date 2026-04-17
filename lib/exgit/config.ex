defmodule Exgit.Config do
  @enforce_keys [:sections]
  defstruct [:sections]

  @type section_key :: {String.t(), String.t() | nil}
  @type t :: %__MODULE__{sections: [{section_key(), [{String.t(), String.t()}]}]}

  @spec new() :: t()
  def new, do: %__MODULE__{sections: []}

  @spec get(t(), String.t(), String.t() | nil, String.t()) :: String.t() | nil
  def get(%__MODULE__{sections: sections}, section, subsection \\ nil, key) do
    key_lower = String.downcase(key)

    Enum.find_value(sections, fn
      {{^section, ^subsection}, entries} ->
        Enum.find_value(entries, fn
          {k, v} -> if String.downcase(k) == key_lower, do: v
        end)

      _ ->
        nil
    end)
  end

  @spec get_all(t(), String.t(), String.t() | nil, String.t()) :: [String.t()]
  def get_all(%__MODULE__{sections: sections}, section, subsection \\ nil, key) do
    key_lower = String.downcase(key)

    Enum.flat_map(sections, fn
      {{^section, ^subsection}, entries} ->
        for {k, v} <- entries, String.downcase(k) == key_lower, do: v

      _ ->
        []
    end)
  end

  @doc """
  Append another value for `key` without replacing existing ones.

  Unlike `set/5` (which replaces), `add/5` preserves existing values.
  This is the equivalent of `git config --add section.key value` and is
  required for multi-valued keys like `remote.<n>.fetch`.
  """
  @spec add(t(), String.t(), String.t() | nil, String.t(), String.t()) :: t()
  def add(%__MODULE__{sections: sections} = config, section, subsection \\ nil, key, value) do
    sec_key = {section, subsection}

    case Enum.find_index(sections, fn {sk, _} -> sk == sec_key end) do
      nil ->
        %{config | sections: sections ++ [{sec_key, [{key, value}]}]}

      idx ->
        {^sec_key, entries} = Enum.at(sections, idx)
        new_entries = entries ++ [{key, value}]
        %{config | sections: List.replace_at(sections, idx, {sec_key, new_entries})}
    end
  end

  @spec set(t(), String.t(), String.t() | nil, String.t(), String.t()) :: t()
  def set(%__MODULE__{sections: sections} = config, section, subsection \\ nil, key, value) do
    sec_key = {section, subsection}
    key_lower = String.downcase(key)

    case Enum.find_index(sections, fn {sk, _} -> sk == sec_key end) do
      nil ->
        %{config | sections: sections ++ [{sec_key, [{key, value}]}]}

      idx ->
        {^sec_key, entries} = Enum.at(sections, idx)

        new_entries =
          case Enum.find_index(entries, fn {k, _} -> String.downcase(k) == key_lower end) do
            nil -> entries ++ [{key, value}]
            i -> List.replace_at(entries, i, {key, value})
          end

        %{config | sections: List.replace_at(sections, idx, {sec_key, new_entries})}
    end
  end

  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write(t(), Path.t()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = config, path) do
    File.write(path, encode(config))
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(text) do
    lines = String.split(text, "\n")
    parse_lines(lines, nil, [], [])
  end

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{sections: sections}) do
    Enum.map(sections, fn {sec_key, entries} ->
      [encode_section_header(sec_key), ?\n | encode_entries(entries)]
    end)
  end

  # --- Parsing ---

  defp parse_lines([], nil, _entries, acc) do
    {:ok, %__MODULE__{sections: Enum.reverse(acc)}}
  end

  defp parse_lines([], sec_key, entries, acc) do
    {:ok, %__MODULE__{sections: Enum.reverse([{sec_key, Enum.reverse(entries)} | acc])}}
  end

  defp parse_lines([line | rest], sec_key, entries, acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") or String.starts_with?(trimmed, ";") ->
        parse_lines(rest, sec_key, entries, acc)

      String.starts_with?(trimmed, "[") ->
        new_acc =
          if sec_key do
            [{sec_key, Enum.reverse(entries)} | acc]
          else
            acc
          end

        case parse_section_header(trimmed) do
          {:ok, new_key} -> parse_lines(rest, new_key, [], new_acc)
          {:error, _} = err -> err
        end

      sec_key != nil ->
        {:ok, key, value} = parse_key_value(trimmed)
        parse_lines(rest, sec_key, [{key, value} | entries], acc)

      true ->
        {:error, {:unexpected_line, trimmed}}
    end
  end

  defp parse_section_header(line) do
    line = String.trim(line)

    cond do
      # [section "subsection"]
      Regex.match?(~r/^\[(\w[\w.-]*)\s+"(.*)"\]$/, line) ->
        [_, section, subsection] = Regex.run(~r/^\[(\w[\w.-]*)\s+"(.*)"\]$/, line)
        {:ok, {String.downcase(section), unescape_subsection(subsection)}}

      # [section]
      Regex.match?(~r/^\[(\w[\w.-]*)\]$/, line) ->
        [_, section] = Regex.run(~r/^\[(\w[\w.-]*)\]$/, line)
        {:ok, {String.downcase(section), nil}}

      true ->
        {:error, {:invalid_section_header, line}}
    end
  end

  defp unescape_subsection(s) do
    s
    |> String.replace("\\\\", "\\")
    |> String.replace("\\\"", "\"")
  end

  defp parse_key_value(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        {:ok, String.trim(key), parse_value(String.trim_leading(value))}

      [key] ->
        # Boolean key (present = true)
        {:ok, String.trim(key), "true"}
    end
  end

  # Single-pass scanner for git config values. Handles:
  #   * unquoted text, stopping at unquoted `#` or `;` (inline comment)
  #   * quoted segments "..." with `\\`, `\"`, `\n`, `\t`, `\b` escapes
  #   * partially-quoted values: pre"mid"post
  #   * trailing whitespace stripped only from the unquoted tail
  @spec parse_value(String.t()) :: String.t()
  defp parse_value(s), do: parse_value(s, [])

  defp parse_value(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary() |> rtrim()

  defp parse_value(<<?", rest::binary>>, acc) do
    {quoted, rest} = scan_quoted(rest, [])
    parse_value(rest, [quoted | acc])
  end

  defp parse_value(<<c, _::binary>>, acc) when c in [?#, ?;] do
    acc |> Enum.reverse() |> IO.iodata_to_binary() |> rtrim()
  end

  defp parse_value(<<?\\, esc, rest::binary>>, acc) do
    parse_value(rest, [unescape_char(esc) | acc])
  end

  defp parse_value(<<c, rest::binary>>, acc) do
    parse_value(rest, [<<c>> | acc])
  end

  # Scan the interior of a quoted segment until the closing `"`.
  defp scan_quoted(<<>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), <<>>}

  defp scan_quoted(<<?", rest::binary>>, acc) do
    {IO.iodata_to_binary(Enum.reverse(acc)), rest}
  end

  defp scan_quoted(<<?\\, esc, rest::binary>>, acc) do
    scan_quoted(rest, [unescape_char(esc) | acc])
  end

  defp scan_quoted(<<c, rest::binary>>, acc) do
    scan_quoted(rest, [<<c>> | acc])
  end

  defp unescape_char(?\\), do: "\\"
  defp unescape_char(?"), do: "\""
  defp unescape_char(?n), do: "\n"
  defp unescape_char(?t), do: "\t"
  defp unescape_char(?b), do: "\b"
  defp unescape_char(c), do: <<c>>

  defp rtrim(s), do: String.trim_trailing(s)

  # --- Encoding ---

  defp encode_section_header({section, nil}), do: ["[", section, "]"]

  defp encode_section_header({section, subsection}) do
    escaped = subsection |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    ["[", section, " \"", escaped, "\"]"]
  end

  defp encode_entries(entries) do
    Enum.map(entries, fn {key, value} ->
      [?\t, key, " = ", escape_value(value), ?\n]
    end)
  end

  defp escape_value(value) do
    if needs_quoting?(value) do
      escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      ["\"", escaped, "\""]
    else
      value
    end
  end

  defp needs_quoting?(value) do
    String.contains?(value, ["\"", "\\", "\n", "\t", "#", ";"]) or
      String.starts_with?(value, " ") or
      String.ends_with?(value, " ")
  end
end
