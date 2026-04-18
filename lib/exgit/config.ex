defmodule Exgit.Config do
  @moduledoc """
  Parser and emitter for git-style INI configuration files.

  `parse/1` accepts arbitrary input — caller- or filesystem-supplied
  text — and returns a tagged `{:ok, _} | {:error, _}` result. It
  never raises on untrusted input.

  ## Threat model

  `.git/config` is treated as **caller-controlled** input, not
  remote-controlled. Exgit does not fetch or persist config received
  over the wire, and it does not **act on** any config value:

    * no `core.sshCommand` / `core.fsmonitor` / `core.hookspath` —
      there is no code path that executes a command out of config
    * no `http.proxy` — Req's proxy comes from env or the explicit
      transport opts, not from config
    * no `insteadOf` / `pushInsteadOf` URL rewriting
    * no `include` / `includeIf` expansion — config files are read
      as-is; `[include] path=...` entries are parsed but ignored
    * no `~/` or `${VAR}` path expansion — paths in config values
      are treated as opaque strings

  This keeps the blast radius of a hostile `.git/config` to "data
  the caller reads back out of `repo.config` and uses themselves."
  A consumer who reads e.g. `Config.get(config, "core", "sshCommand")`
  and hands it to `System.cmd/2` is outside exgit's trust boundary.

  **If submodule support is added**, `.gitmodules` URLs become a
  remote-controlled surface and will need separate validation —
  refusing `file://`, `ssh://user@host/…;command`, and any URL
  containing shell-metacharacters. Not currently present.
  """

  # Pre-compiled at module load. Previously inline `~r/.../` sigils
  # were re-parsed on every `parse_section_header/1` call (four
  # times per section line), which showed up on any config-heavy
  # workflow.
  @section_header_subsection ~r/^\[(\w[\w.-]*)\s+"(.*)"\]$/
  @section_header_plain ~r/^\[(\w[\w.-]*)\]$/

  @enforce_keys [:sections]
  defstruct [:sections]

  @type section_key :: {String.t(), String.t() | nil}
  @type t :: %__MODULE__{sections: [{section_key(), [{String.t(), String.t()}]}]}

  @spec new() :: t()
  def new, do: %__MODULE__{sections: []}

  @spec get(t(), String.t(), String.t() | nil, String.t()) :: String.t() | nil
  def get(%__MODULE__{sections: sections}, section, subsection \\ nil, key) do
    section_lower = String.downcase(section)
    key_lower = String.downcase(key)

    Enum.find_value(sections, fn
      {{^section_lower, ^subsection}, entries} ->
        Enum.find_value(entries, fn
          {k, v} -> if String.downcase(k) == key_lower, do: v
        end)

      _ ->
        nil
    end)
  end

  @spec get_all(t(), String.t(), String.t() | nil, String.t()) :: [String.t()]
  def get_all(%__MODULE__{sections: sections}, section, subsection \\ nil, key) do
    section_lower = String.downcase(section)
    key_lower = String.downcase(key)

    Enum.flat_map(sections, fn
      {{^section_lower, ^subsection}, entries} ->
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
    # Git treats section names case-insensitively. Store the
    # downcased form so that `add("CORE", ...)` and
    # `add("core", ...)` address the same section, and so that
    # parse/encode roundtrip is a fixpoint regardless of casing
    # in the caller's input. Subsection names are case-sensitive
    # per git's rules.
    sec_key = {String.downcase(section), subsection}

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
    sec_key = {String.downcase(section), subsection}
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
        # parse_key_value is total — every binary input returns
        # `{:ok, key, value}`. If that ever changes (a future branch
        # adds validation that may fail), this match will fail at
        # compile-time on 1.19+ due to type inference, so the caller
        # MUST update this call site alongside the return-shape
        # change. Do not "future-proof" with a dead `{:error, _}`
        # clause — Elixir 1.19's type checker rejects unreachable
        # patterns under --warnings-as-errors.
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
      Regex.match?(@section_header_subsection, line) ->
        [_, section, subsection] = Regex.run(@section_header_subsection, line)
        {:ok, {String.downcase(section), unescape_subsection(subsection)}}

      # [section]
      Regex.match?(@section_header_plain, line) ->
        [_, section] = Regex.run(@section_header_plain, line)
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
