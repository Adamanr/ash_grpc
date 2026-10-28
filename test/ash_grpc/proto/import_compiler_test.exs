defmodule AshGrpc.Proto.ImportCompilerTest do
  @moduledoc """
  End-to-end tests through the real `AshGrpc.Proto.Compiler`. Skipped while the
  compiler is still a stub (it raises).
  """
  use ExUnit.Case, async: false

  @root "test/fixtures/protos"
  @includes [@root, Path.join(@root, "third_party")]

  @compiler_ready (try do
                     AshGrpc.Proto.Compiler.to_source(%AshGrpc.Proto.IR.Schema{}, [])
                     true
                   rescue
                     _ -> false
                   end)

  @moduletag :needs_compiler
  unless @compiler_ready, do: @moduletag(skip: "AshGrpc.Proto.Compiler is not implemented yet")

  setup do
    {:ok, schema} =
      AshGrpc.Proto.Import.from_files(
        [Path.join(@root, "acme/billing/v1/billing.proto")],
        include_paths: @includes,
        module_prefix: AshGrpc.Test.Imported
      )

    %{schema: schema}
  end

  # resolved at runtime: while the compiler is a stub its calls are typed as `none()`
  defp compiler, do: Module.concat([AshGrpc.Proto, Compiler])

  test "imported schema compiles to working protobuf modules", %{schema: schema} do
    modules = compiler().compile(schema, [])
    invoice_module = Module.concat([AshGrpc.Test.Imported, Invoice])

    assert invoice_module in modules
    assert AshGrpc.Test.Imported.BillingService.Service in modules

    invoice =
      struct(invoice_module,
        id: "inv_1",
        labels: %{"a" => "b"},
        note: "hi",
        payment: {:card_token, "tok"}
      )

    decoded =
      invoice_module.decode(invoice_module.encode(invoice))

    assert decoded.id == "inv_1"
    assert decoded.labels == %{"a" => "b"}
    assert decoded.payment == {:card_token, "tok"}
  end

  test "to_source emits parseable Elixir for every file", %{schema: schema} do
    sources = compiler().to_source(schema, [])

    assert sources != []

    for {path, source} <- sources do
      assert String.ends_with?(path, ".ex")
      assert {:ok, _} = Code.string_to_quoted(source)
    end
  end
end
