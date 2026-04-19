# Complexity audit: grep-level + AST-level scan for patterns that
# usually indicate worse-than-O(n) behavior in Elixir code.
#
# Run with:
#
#   elixir scripts/complexity_audit.exs                  # all of lib/
#   elixir scripts/complexity_audit.exs lib test         # specific dirs
#   elixir scripts/complexity_audit.exs --format=json    # machine-readable
#
# The script emits one line per finding, with severity:
#
#   HIGH   — almost certainly quadratic under load. Pair patterns:
#            `Enum.find_index + List.replace_at`, `++ [x]` inside
#            `Enum.reduce`, `<>` binary concat accumulator.
#   MED    — probably quadratic when called N times over same data.
#            Single `Enum.find`, `Enum.at` outside the base case,
#            `length(...)` in a conditional, `List.last/1`.
#   LOW    — worth a look but may be fine. `Enum.uniq` on list,
#            `-- [...]`.
#
# Output shape:
#
#   HIGH  lib/exgit/config.ex:106  Enum.find_index + List.replace_at pair
#         |> Classic O(n²) insert pattern; use Map keyed by name or
#            prepend + reverse.
#
# Limitations (honest ones):
#
#   * Regex-based; false positives in comments, strings, and docs
#     are possible. Filter with leading whitespace where safe.
#   * AST checks only go one function deep — doesn't trace a helper
#     called in a loop to find N²-across-functions patterns.
#   * Can't tell hot from cold paths. An `Enum.at` in a boot-only
#     config parser is technically O(n²) but won't ever matter.
#   * **Not every flagged pattern is a real perf problem.** The
#     BEAM has specific optimizations that amortize some patterns
#     which look quadratic from source. Biggest example:
#
#       acc <> binary        # inside reduce, acc referenced
#                            # only linearly
#
#     BEAM amortizes this to O(total_bytes) via in-place append on
#     refc binaries. An author of this tool tested a 26KB signed
#     commit with 400-line continuation concat: iodata form and
#     `<>` form were statistically identical (~200µs per parse).
#     When the tool flags a `<>` inside a reduce, it's a :med
#     ("worth a look") not :high ("fix this").
#
#     Always benchmark before "fixing" a flagged pattern. The tool
#     is a hint, not a verdict.

defmodule ComplexityAudit do
  # Note: `finding` as a type would be documented here, but Elixir
  # emits "type finding/0 is unused" when a @typep is only referenced
  # in comments/docs. Kept inline in docs for human readers.
  #
  #   %{severity: :high | :med | :low,
  #     file: String.t(),
  #     line: pos_integer(),
  #     rule: atom(),
  #     snippet: String.t(),
  #     explanation: String.t()}

  # --- Rules ---
  #
  # Each rule is {severity, label, regex, explanation, filter_fn}.
  # The filter_fn receives the matched line + surrounding context
  # and returns true to keep the finding, false to drop it.
  #
  # Regexes are anchored on the hit position; we scan each file's
  # lines individually rather than one big regex pass.

  @rules [
    # ---------------- HIGH-severity patterns ----------------

    {:high, :list_append_in_pipeline, ~r/\+\+\s*\[[^\]]/,
     "`list ++ [item]` is O(n) per call. Building a list this way inside a loop is O(n²). Prefer prepend + `Enum.reverse/1` at the end, or use an iodata/map/MapSet as the accumulator.",
     &__MODULE__.list_append_in_loop_context/3},
    {:high, :list_replace_at, ~r/List\.replace_at\(/,
     "`List.replace_at/3` is O(n). Paired with `Enum.find_index/2` (common), insert-by-name loops become O(n²). Consider keying by a map and rebuilding the list only at serialization time.",
     &__MODULE__.not_in_comment/3},
    {:high, :list_insert_at, ~r/List\.insert_at\(/,
     "`List.insert_at/3` is O(n). Same reasoning as `List.replace_at`.",
     &__MODULE__.not_in_comment/3},
    {:high, :list_delete_at, ~r/List\.delete_at\(/,
     "`List.delete_at/2` is O(n). In a filter loop, prefer `Enum.reject/2` or filter+rebuild.",
     &__MODULE__.not_in_comment/3},
    # NOTE: demoted from HIGH to MED after empirical testing.
    # BEAM's binary-append optimization means that `acc <> x` inside a
    # reduce, where `acc` is a refc binary in the linear scope of the
    # reduce, is append-in-place and amortizes to O(N), not O(N²).
    # The optimization covers the common pattern. A change from
    # `val <> "\n" <> rest` (inside a reduce with ~2000 iterations) to
    # an iodata-accumulating form measured at 200µs regardless of
    # version, on Erlang/OTP 28. Still worth flagging at MED because
    # the optimization can be defeated if the accumulator escapes
    # scope, is concatenated at a non-tail position, or is captured
    # in a closure — but don't assume all `<>` in reduce is a problem.
    {:med, :binary_concat_in_reduce, ~r/<>\s*[a-z_][a-zA-Z_0-9]*/,
     "Binary concatenation with `<>` on a growing accumulator CAN be O(n²), but BEAM's binary-append optimization covers the common `acc <> x` pattern inside a reduce — it becomes amortized O(n). Only a real problem if the accumulator escapes the linear scope, is concatenated at a non-tail position, or the BEAM can't trace the append. Worth a look, not a must-fix.",
     &__MODULE__.concat_looks_like_accumulator/3},

    # ---------------- MED-severity patterns ----------------

    {:med, :length_in_body, ~r/\blength\(/,
     "`length/1` is O(n). Fine in type-check guards (compile-time optimization), but inside a conditional / loop body it's a trap. Track count in an accumulator or use `[] =` / `[_ | _] =` pattern matches.",
     &__MODULE__.not_guard_and_not_comment/3},
    {:med, :enum_find, ~r/Enum\.find\(/,
     "`Enum.find/2` is O(n). Called repeatedly over the same collection, it's O(n²). Consider a MapSet / map keyed by the search criterion.",
     &__MODULE__.not_in_comment/3},
    {:med, :enum_find_index, ~r/Enum\.find_index\(/,
     "`Enum.find_index/2` is O(n). Nearly always appears next to `List.replace_at` — see that rule. Consider keyed structures.",
     &__MODULE__.not_in_comment/3},
    {:med, :enum_at, ~r/Enum\.at\(/,
     "`Enum.at/2` on a list is O(n) for indexed access. Inside `Enum.map/reduce` iterating the same list, it's O(n²). Use `Enum.with_index` + pattern match, or `Enum.zip`.",
     &__MODULE__.not_in_comment/3},
    {:med, :enum_member, ~r/Enum\.member\?\(/,
     "`Enum.member?/2` on a list is O(n). Use `MapSet.member?/2` for any set that's queried more than a few times.",
     &__MODULE__.not_in_comment/3},
    {:med, :list_last, ~r/List\.last\(/,
     "`List.last/1` is O(n). If you need frequent last-access, store the collection differently — reverse the list so head is last, or use a tuple.",
     &__MODULE__.not_in_comment/3},
    {:med, :list_subtract, ~r/\-\-\s*\[/,
     "List subtraction `--` is O(n*m). Convert to MapSet for large collections.",
     &__MODULE__.not_in_comment/3},

    # ---------------- LOW-severity patterns ----------------

    {:low, :enum_uniq_no_by, ~r/Enum\.uniq\(/,
     "`Enum.uniq/1` on a list is O(n) wall-clock but uses a MapSet internally — actually fine. Flagged at :low so a human can glance and confirm; if you see `Enum.uniq(list_of_tuples)` on huge data, use `Enum.uniq_by/2`.",
     &__MODULE__.not_in_comment/3},
    {:low, :enum_sort_with_find, ~r/Enum\.sort_by\(/,
     "`Enum.sort_by/2` is O(n log n). When the key function is itself O(n) (e.g. contains `Enum.find`), total is O(n² log n). Verify the key fn is O(1) amortized.",
     &__MODULE__.not_in_comment/3},
    {:low, :keyword_get_in_loop, ~r/Keyword\.get\(/,
     "`Keyword.get/2` is O(n). Fine for option parsing at function entry; bad inside a per-item loop over a large keyword list.",
     &__MODULE__.not_in_comment/3}
  ]

  # ---- Entry point ----

  def main(argv) do
    {opts, paths, _} =
      OptionParser.parse(argv,
        switches: [format: :string, severity: :string, help: :boolean],
        aliases: [f: :format, s: :severity, h: :help]
      )

    if opts[:help] do
      usage()
      System.halt(0)
    end

    paths = if paths == [], do: ["lib"], else: paths
    min_sev = parse_severity(opts[:severity] || "low")

    findings =
      paths
      |> expand_files()
      |> Enum.flat_map(&scan_file/1)
      |> Enum.filter(fn f -> sev_rank(f.severity) >= sev_rank(min_sev) end)
      |> pair_detection()
      |> Enum.sort_by(&{sev_rank(&1.severity) * -1, &1.file, &1.line})

    case opts[:format] || "human" do
      "json" -> emit_json(findings)
      "summary" -> emit_summary(findings)
      _ -> emit_human(findings)
    end

    exit_code =
      cond do
        findings == [] -> 0
        has_high?(findings) -> 1
        true -> 0
      end

    System.halt(exit_code)
  end

  defp usage do
    IO.puts("""
    complexity_audit — scan Elixir source for patterns usually indicating
    worse-than-O(n) behavior.

    Usage:
      elixir scripts/complexity_audit.exs [options] [paths...]

    Options:
      -f, --format FORMAT     human (default) | json | summary
      -s, --severity LEVEL    minimum severity to report: high, med, low
      -h, --help              this text

    Exit codes:
      0 — no findings above threshold, OR only medium/low findings
      1 — at least one HIGH finding (CI can gate on this)

    Examples:
      elixir scripts/complexity_audit.exs
      elixir scripts/complexity_audit.exs lib test
      elixir scripts/complexity_audit.exs -s high
      elixir scripts/complexity_audit.exs --format=json > findings.json
    """)
  end

  defp sev_rank(:high), do: 3
  defp sev_rank(:med), do: 2
  defp sev_rank(:low), do: 1

  defp parse_severity("high"), do: :high
  defp parse_severity("med"), do: :med
  defp parse_severity(_), do: :low

  defp has_high?(findings), do: Enum.any?(findings, &(&1.severity == :high))

  # ---- File expansion ----

  defp expand_files(paths) do
    paths
    |> Enum.flat_map(fn p ->
      cond do
        File.dir?(p) ->
          Path.wildcard(Path.join(p, "**/*.{ex,exs}"))

        File.regular?(p) ->
          [p]

        true ->
          IO.puts(:stderr, "warning: #{p} not found, skipping")
          []
      end
    end)
    |> Enum.uniq()
    # Skip the audit script itself (would flag every rule's regex literal).
    |> Enum.reject(&String.ends_with?(&1, "complexity_audit.exs"))
    # Skip deps.
    |> Enum.reject(&String.contains?(&1, "/deps/"))
  end

  # ---- Line-level scan ----

  defp scan_file(path) do
    lines =
      path
      |> File.read!()
      |> String.split("\n")

    for {line, idx} <- Enum.with_index(lines, 1),
        {sev, rule, regex, explanation, filter_fn} <- @rules,
        Regex.match?(regex, line),
        filter_fn.(line, lines, idx) do
      %{
        severity: sev,
        file: path,
        line: idx,
        rule: rule,
        snippet: String.trim(line),
        explanation: explanation
      }
    end
  end

  # ---- Filter helpers (public so @rules can reference them) ----

  def not_in_comment(line, _all_lines, _idx) do
    trimmed = String.trim_leading(line)
    not String.starts_with?(trimmed, "#")
  end

  def not_guard_and_not_comment(line, all_lines, idx) do
    cond do
      # `length/1` in guards is still O(n) at runtime — BEAM doesn't
      # compile-time optimize it the way people assume. The only
      # exception is `when length(l) == 0` which pattern-matches to
      # empty-list (and you should just write `[]` anyway). We flag
      # every other `when length(...)` as a real finding.
      String.contains?(line, "when") and
          Regex.match?(~r/length\([^)]+\)\s*(==|>=|<=|>|<|!=)/, line) ->
        true

      String.contains?(line, "when ") ->
        false

      not not_in_comment(line, all_lines, idx) ->
        false

      true ->
        true
    end
  end

  # `list ++ [item]` is only a real problem when it's inside a
  # per-iteration accumulator build. We use two heuristics:
  #
  #   1. The function this line is in ALSO contains `Enum.find_index`
  #      or `Enum.find` — strong signal for the mutate-by-name pattern.
  #   2. Loop-shape context on surrounding lines (Enum.reduce, for,
  #      recursion on the same variable, etc.).
  #
  # Calls to `a ++ [b]` in pure option-building / constant-data
  # functions (e.g. `base ++ [transport_opts: ...]` called once)
  # don't match either heuristic and get filtered out.
  def list_append_in_loop_context(line, all_lines, idx) do
    cond do
      not not_in_comment(line, all_lines, idx) ->
        false

      # `for e <- source, do: e ++ [...]` — the `++` is on the
      # iteration variable, not a growing accumulator. Safe O(|e|)
      # per iteration, not O(n²).
      Regex.match?(~r/\bfor\s+\w+\s*<-.*,\s*do:.*\+\+\s*\[/, line) ->
        false

      function_has_find?(all_lines, idx) ->
        true

      loop_shape_near?(all_lines, idx) ->
        true

      true ->
        false
    end
  end

  # Look backward from `idx` for the enclosing `def`/`defp` line,
  # then scan from there to `idx + 30` for find_index/find.
  defp function_has_find?(lines, idx) do
    start = find_enclosing_def(lines, idx)
    window = Enum.slice(lines, start..(idx + 30)//1)

    Enum.any?(window, fn l ->
      Regex.match?(~r/Enum\.find(_index)?\(/, l)
    end)
  end

  defp find_enclosing_def(lines, idx) do
    idx..0//-1
    |> Enum.find(fn i ->
      line = Enum.at(lines, i - 1) || ""
      Regex.match?(~r/^\s*defp?\s/, line)
    end)
    |> case do
      nil -> 0
      i -> i - 1
    end
  end

  # `<> bar` is a binary concat. It's only an accumulator footgun
  # when the LHS is something that grows (a variable rebound in
  # reduce, a module attribute, etc.).
  #
  # Heuristic: flag only when the `<>` appears on a line that ALSO
  # looks like part of a reduce / loop body. Keywords we look for
  # in a 3-line window: `reduce`, `fn`, `<-`, `Enum.`, `|>`.
  def concat_looks_like_accumulator(line, all_lines, idx) do
    cond do
      not not_in_comment(line, all_lines, idx) ->
        false

      # Skip binary-pattern matches like `<<_::32>> <> rest = bin`.
      String.contains?(line, "::") ->
        false

      # Skip pattern-match syntax where `<>` is the binary prefix
      # matcher — e.g. `{" " <> rest, acc}` inside a case, or
      # `"foo" <> bar -> ...` at clause head. These are destructuring
      # operations, not concatenation. Heuristic: the line starts
      # with an open brace / pipe / arrow position indicator, OR
      # contains ` -> ` AFTER the concat.
      pattern_match_context?(line) ->
        false

      # Skip string-concat in guards / simple expressions; require
      # a loop-shaped context on the current or preceding line.
      loop_shape_near?(all_lines, idx) ->
        true

      true ->
        false
    end
  end

  defp pattern_match_context?(line) do
    trimmed = String.trim_leading(line)

    # Clause heads and case/fn patterns start with these shapes. If
    # we see a `<>` before an arrow `->`, it's a pattern match.
    cond do
      Regex.match?(~r/^[\{\[]\s*"[^"]*"\s*<>/, trimmed) -> true
      Regex.match?(~r/^"[^"]*"\s*<>.*->/, trimmed) -> true
      Regex.match?(~r/<>\s*\w+,\s*[\[\{]/, trimmed) -> true
      true -> false
    end
  end

  defp loop_shape_near?(lines, idx) do
    window = Enum.slice(lines, max(0, idx - 3)..(idx + 1)//1)

    Enum.any?(window, fn l ->
      Regex.match?(~r/(Enum\.reduce|Enum\.map_reduce|\bfor\b.*<-|&\s*(\+|\-|<>))/, l)
    end)
  end

  # ---- Cross-rule pair detection ----

  # If `Enum.find_index` and `List.replace_at` both appear in the
  # same 15-line window, promote both to :high with a pair-rule
  # tag. This is the canonical "mutate-list-by-name" O(n²) pattern.
  defp pair_detection(findings) do
    find_index = Enum.filter(findings, &(&1.rule == :enum_find_index))
    replace_at = Enum.filter(findings, &(&1.rule == :list_replace_at))

    pairs =
      for fi <- find_index,
          ra <- replace_at,
          fi.file == ra.file,
          abs(fi.line - ra.line) <= 15 do
        {min(fi.line, ra.line), max(fi.line, ra.line), fi.file}
      end
      |> Enum.uniq()

    pair_file_line_set =
      pairs
      |> Enum.flat_map(fn {lo, hi, f} -> for l <- lo..hi, do: {f, l} end)
      |> MapSet.new()

    # Promote existing findings inside a pair window; append one
    # synthetic finding per pair to flag the pair itself.
    promoted =
      Enum.map(findings, fn f ->
        if MapSet.member?(pair_file_line_set, {f.file, f.line}) do
          %{f | severity: :high}
        else
          f
        end
      end)

    synthetic =
      for {lo, _hi, f} <- pairs do
        %{
          severity: :high,
          file: f,
          line: lo,
          rule: :find_index_plus_replace_at_pair,
          snippet: "<pair pattern>",
          explanation:
            "Enum.find_index + List.replace_at within ~15 lines is the classic 'mutate a list by name' O(n²) shape. N insertions into an N-element list cost N * O(N) = O(N²). Prefer a Map keyed by name (rebuild the list only at serialization time) or, if order matters, Map + ordered keys list."
        }
      end

    promoted ++ synthetic
  end

  # ---- Output formatters ----

  defp emit_human([]) do
    IO.puts("\n✓ No complexity red flags found.\n")
  end

  defp emit_human(findings) do
    IO.puts("\nComplexity audit — #{length(findings)} finding(s):\n")

    for f <- findings do
      color = sev_color(f.severity)
      reset = IO.ANSI.reset()

      IO.puts("#{color}#{sev_label(f.severity)}#{reset}  #{f.file}:#{f.line}  #{f.rule}")
      IO.puts("      #{IO.ANSI.faint()}#{f.snippet}#{reset}")

      f.explanation
      |> wrap_text(72, "      |> ")
      |> IO.puts()

      IO.puts("")
    end

    summary_line(findings)
  end

  defp emit_summary(findings) do
    by_sev = Enum.group_by(findings, & &1.severity)
    h = length(Map.get(by_sev, :high, []))
    m = length(Map.get(by_sev, :med, []))
    l = length(Map.get(by_sev, :low, []))
    IO.puts("HIGH=#{h} MED=#{m} LOW=#{l} TOTAL=#{length(findings)}")
  end

  defp emit_json(findings) do
    findings
    |> Enum.map(&Map.take(&1, [:severity, :file, :line, :rule, :snippet, :explanation]))
    |> inspect(pretty: true, limit: :infinity)
    |> IO.puts()
  end

  defp summary_line(findings) do
    by_sev = Enum.frequencies_by(findings, & &1.severity)
    h = Map.get(by_sev, :high, 0)
    m = Map.get(by_sev, :med, 0)
    l = Map.get(by_sev, :low, 0)
    IO.puts("Summary: #{h} HIGH, #{m} MED, #{l} LOW (#{length(findings)} total)")
  end

  defp sev_label(:high), do: "HIGH"
  defp sev_label(:med), do: " MED"
  defp sev_label(:low), do: " LOW"

  defp sev_color(:high), do: IO.ANSI.red() <> IO.ANSI.bright()
  defp sev_color(:med), do: IO.ANSI.yellow()
  defp sev_color(:low), do: IO.ANSI.cyan()

  defp wrap_text(text, width, prefix) do
    text
    |> String.split(~r/\s+/)
    |> Enum.reduce({[], ""}, fn word, {lines, current} ->
      candidate = if current == "", do: word, else: current <> " " <> word

      if String.length(candidate) > width do
        {[current | lines], word}
      else
        {lines, candidate}
      end
    end)
    |> then(fn {lines, last} -> Enum.reverse([last | lines]) end)
    |> Enum.map_join("\n", fn line -> prefix <> line end)
  end
end

ComplexityAudit.main(System.argv())
