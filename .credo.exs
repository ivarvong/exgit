%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: ["_build/", "deps/"]
      },
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: [
        # Enforce module-level docs on public library modules, but
        # not on test modules, test-only fakes, or private helper
        # modules declared inside a test file.
        {Credo.Check.Readability.ModuleDoc,
         files: %{included: ["lib/**/*.ex"], excluded: ["lib/**/test*.ex"]}},

        # Specs on every public function is aspirational but not yet
        # complete; disabled for now to avoid a massive noisy diff.
        {Credo.Check.Readability.Specs, false},

        # Nested aliases are fine: `alias Exgit.{A, B}`.
        {Credo.Check.Readability.AliasAs, false},

        # Trailing blank lines at EOF are harmless; `mix format`
        # handles them.
        {Credo.Check.Readability.TrailingBlankLine, false},

        # `Credo.Check.Design.AliasUsage` flags every dot-qualified
        # module reference (e.g. `Exgit.Object.Blob.new/1`) and
        # suggests a top-of-module alias. For a library whose public
        # API is literally `Exgit.Object.Blob` etc., this produces
        # ~60 false positives where the dot-qualified form IS the
        # canonical reference. Disabled; we alias what genuinely
        # benefits from it and leave canonical dot-qualified
        # references alone.
        {Credo.Check.Design.AliasUsage, false},

        # `Credo.Check.Refactor.Nesting` has a default max depth of
        # 2, which would flag virtually every `case ... do` inside an
        # `Enum.flat_map` / `with` — idioms we use everywhere for
        # well-structured error handling. Bump to 4, which still
        # catches genuinely over-nested code while accepting the
        # common patterns.
        {Credo.Check.Refactor.Nesting, max_nesting: 4},

        # `Credo.Check.Refactor.CyclomaticComplexity` defaults to 9,
        # which is tighter than Elixir community norms. 12 is the
        # common production-code setting and still catches the
        # genuinely hairy functions (a 20+ branching function is a
        # real smell).
        {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 12},

        # `Cond` with a single guard + `true` branch is a valid
        # pattern when the single guard is complex / makes reading
        # easier; Credo's suggestion of `if` is sometimes a regression
        # in clarity. Keep this advisory; don't fail on it.
        {Credo.Check.Refactor.CondStatements, false}
      ]
    }
  ]
}
