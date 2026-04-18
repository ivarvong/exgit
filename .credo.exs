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
        # Enforce module-level docs on public library modules.
        {Credo.Check.Readability.ModuleDoc, files: %{included: ["lib/**/*.ex"]}},

        # Keep the default set of readability / consistency / design
        # checks. Selectively disable ones that collide with our style:
        #
        #   - Specs on every public function is aspirational but not
        #     yet complete; disabled for now to avoid a massive noisy
        #     diff.
        {Credo.Check.Readability.Specs, false},

        # Nested aliases are fine: `alias Exgit.{A, B}`.
        {Credo.Check.Readability.AliasAs, false},

        # Trailing blank lines at EOF are harmless and `mix format`
        # handles them.
        {Credo.Check.Readability.TrailingBlankLine, false}
      ]
    }
  ]
}
