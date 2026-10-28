defmodule AshGrpc.E2E.CompatibilityTest do
  # Evolving a served resource: V1 → V2 (field added) → V3 (fields removed), running codegen
  # after every change. Field numbers must stay, removed fields must become reserved, and a
  # client compiled from the V1 .proto must keep working against the V2 and V3 servers.
  use ExUnit.Case, async: false

  alias AshGrpc.Test.E2E.Shelves.{V1, V2, V3}
  alias AshGrpc.Test.Protoc

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag :capture_log

  unless Protoc.available?(), do: @moduletag(skip: "protoc is required")

  @proto "ashgrpc/e2e/shelves/v1/shelves.proto"
  @old AshGrpc.Test.E2E.OldShelves

  setup %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{
      out: Path.join(dir, "protos"),
      lock: Path.join(dir, "lock.json"),
      snapshots: Path.join(dir, "snapshots"),
      dir: dir
    }
  end

  defp codegen!(domain, ctx, flags \\ []) do
    Mix.Task.reenable("ash_grpc.codegen")

    Mix.Tasks.AshGrpc.Codegen.run(
      [
        "--domains",
        inspect(domain),
        "--out",
        ctx.out,
        "--lock",
        ctx.lock,
        "--snapshots",
        ctx.snapshots,
        "--quiet"
      ] ++ flags
    )

    File.read!(Path.join(ctx.out, @proto))
  end

  # An endpoint compiled now, against the lock codegen just wrote (as a deployed server would be).
  defp serve!(domain, lock) do
    name = Module.concat([AshGrpc.Test.E2E, "#{List.last(Module.split(domain))}Endpoint"])

    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use AshGrpc.Endpoint,
            otp_app: :ash_grpc,
            domains: [unquote(domain)],
            lock_path: unquote(lock),
            require_lock?: true,
            health: false
        end
      end
    )

    start_supervised!({AshGrpc.Server, endpoint: name, port: 0}, id: name)
    AshGrpc.Server.port(name)
  end

  defp old_client!(old_proto_dir, ports) do
    {:ok, schema} =
      AshGrpc.Proto.Import.from_files([Path.join(old_proto_dir, @proto)],
        include_paths: [old_proto_dir],
        module_prefix: @old
      )

    AshGrpc.Proto.Compiler.compile(schema, [])

    for {name, port} <- ports do
      start_supervised!(
        {AshGrpc.Client,
         name: name,
         services: [Module.concat(@old, "ShelvesService.Service")],
         address: "127.0.0.1:#{port}",
         map_errors: false},
        id: name
      )
    end
  end

  defp field_line(proto, field) do
    proto |> String.split("\n") |> Enum.find(&(&1 =~ ~r/\s#{field} = \d+;/)) |> String.trim()
  end

  test "numbers stay, removed fields are reserved, old clients keep working", ctx do
    v1 = codegen!(V1, ctx)
    old_dir = Path.join(ctx.dir, "v1")
    File.cp_r!(ctx.out, old_dir)

    assert field_line(v1, "name") == "string name = 2;"
    assert field_line(v1, "size") == "optional int64 size = 3;"
    assert field_line(v1, "inserted_at") == "google.protobuf.Timestamp inserted_at = 4;"

    # add a field: existing numbers are kept, the new one gets the next free number
    v2 = codegen!(V2, ctx)
    assert field_line(v2, "size") == field_line(v1, "size")
    assert field_line(v2, "inserted_at") == field_line(v1, "inserted_at")
    assert field_line(v2, "color") == "optional string color = 5;"
    assert codegen!(V2, ctx, ["--check"]) == v2
    v2_port = serve!(V2, ctx.lock)

    # remove fields: not breaking, numbers and names are reserved
    v3 = codegen!(V3, ctx)
    refute v3 =~ ~r/\bsize = /
    refute v3 =~ ~r/\bcolor = /
    assert field_line(v3, "name") == field_line(v1, "name")
    assert field_line(v3, "inserted_at") == field_line(v1, "inserted_at")
    assert v3 =~ ~r/reserved 3, 5;/
    assert v3 =~ ~r/reserved "color", "size";/
    assert codegen!(V3, ctx, ["--check"]) == v3
    v3_port = serve!(V3, ctx.lock)

    # the reserved protos still compile
    assert %Google.Protobuf.FileDescriptorSet{} = Protoc.descriptor_set!(ctx.out, [@proto])

    old_client!(old_dir, old_v2: v2_port, old_v3: v3_port)
    shelf = Module.concat(@old, "Shelf")

    # V2 answers with a field the old client does not know: it is skipped
    assert {:ok, %{__struct__: ^shelf} = created} =
             AshGrpc.Client.call(:old_v2, :create_shelf, %{name: "Oak", size: 3})

    assert %{name: "Oak", size: 3} = created

    assert {:ok, %{name: "Oak", size: 3}} =
             AshGrpc.Client.call(:old_v2, :get_shelf, %{id: created.id})

    # V3 no longer has `size`: the old client's value is ignored and decodes as absent
    assert {:ok, %{__struct__: ^shelf} = created} =
             AshGrpc.Client.call(:old_v3, :create_shelf, %{name: "Pine", size: 7})

    assert %{name: "Pine", size: nil} = created
    assert %Google.Protobuf.Timestamp{} = created.inserted_at
    assert {:ok, %{shelves: [%{name: "Pine"}]}} = AshGrpc.Client.call(:old_v3, :list_shelves, %{})
  end

  test "re-adding a removed field under its old name is refused", ctx do
    codegen!(V2, ctx)
    codegen!(V3, ctx)

    error = assert_raise Mix.Error, fn -> codegen!(V2, ctx) end
    assert error.message =~ "Shelf.size: name is reserved"
    assert error.message =~ "Shelf.color: name is reserved"
  end
end
