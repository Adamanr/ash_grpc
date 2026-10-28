defmodule AshGrpc.PipelineTest do
  @moduledoc """
  Cross-package check: DSL → `AshGrpc.Schema` → `Proto.Compiler` → `AshGrpc.Codec` → wire.
  """
  use ExUnit.Case, async: false

  alias AshGrpc.{Codec, Schema}
  alias AshGrpc.Proto.{Compiler, IR, Render}
  alias AshGrpc.Test.{Accounts, Catalog}

  setup_all do
    {:ok, schema} = Schema.build([Accounts, Catalog])
    Compiler.compile(schema)
    %{schema: schema}
  end

  defp message(schema, full_name) do
    {:ok, %IR.Message{} = message} = IR.Schema.lookup(schema, full_name)
    message
  end

  test "every file of the built schema renders", %{schema: schema} do
    for file <- schema.files do
      assert file |> Render.render() |> IO.iodata_to_binary() =~ "package #{file.package};"
    end
  end

  test "a record survives encode → wire → decode", %{schema: schema} do
    user_message = message(schema, "ashgrpc.test.accounts.v1.User")
    module = user_message.module
    assert Code.ensure_loaded?(module)

    id = Ash.UUID.generate()
    inserted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    record =
      struct(AshGrpc.Test.User,
        id: id,
        email: "ada@example.com",
        name: "Ada",
        age: 36,
        role: :admin,
        active: true,
        tags: ["math", "engines"],
        inserted_at: inserted_at
      )

    assert {:ok, %^module{} = encoded} = Codec.encode_record(record, user_message, schema)
    assert %^module{} = decoded = encoded |> module.encode() |> module.decode()

    assert {:ok, values} = Codec.decode_message(decoded, user_message, schema)
    assert values.id == id
    assert values.email == "ada@example.com"
    assert values.role == :admin
    assert values.tags == ["math", "engines"]
    assert values.active == true
    assert DateTime.compare(values.inserted_at, inserted_at) == :eq
  end

  test "action input messages decode into Ash input", %{schema: schema} do
    request = message(schema, "ashgrpc.test.accounts.v1.SignUpRequest")
    module = request.module

    wire =
      module
      |> struct(email: "grace@example.com", password: "secret", age: 40)
      |> module.encode()

    assert {:ok, input} = Codec.decode_message(module.decode(wire), request, schema)
    assert input.email == "grace@example.com"
    assert input.password == "secret"
    assert input.age == 40
    # absent optional fields stay absent so Ash defaults apply
    refute Map.has_key?(input, :name)
  end
end
