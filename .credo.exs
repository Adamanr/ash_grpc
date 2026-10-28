%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true,
      checks: %{
        disabled: [
          # Typespecs and DSL schemas reference fully-qualified modules on purpose.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
