defmodule AshGrpc.Proto.CompilerTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.{Compiler, IR}
  alias AshGrpc.Test.ProtoFixtures

  doctest Compiler

  @prefix AshGrpc.Test.CompilerTest.V1

  setup_all do
    schema =
      ProtoFixtures.schema([
        ProtoFixtures.shop_file(@prefix),
        ProtoFixtures.legacy_file(AshGrpc.Test.CompilerTest.Legacy)
      ])

    Compiler.compile(schema)
    %{schema: schema}
  end

  defp mod(name), do: Module.concat(@prefix, name)

  describe "quoted/2" do
    test "returns defmodule ASTs ordered enums, messages, services, stubs", %{schema: schema} do
      modules = schema |> Compiler.quoted() |> Enum.map(&elem(&1, 0))

      assert modules == [
               mod(Role),
               mod(User.Status),
               AshGrpc.Test.CompilerTest.Legacy.Kind,
               mod(User.Address),
               mod(User.AttributesEntry),
               mod(User.RoleByOrgEntry),
               mod(User.AddressesEntry),
               mod(User),
               mod(GetUserRequest),
               mod(ListUsersRequest),
               AshGrpc.Test.CompilerTest.Legacy.Item,
               mod(UserService.Service),
               mod(UserService.Stub)
             ]

      assert {_, {:defmodule, _, _}} = hd(Compiler.quoted(schema))
    end

    test "editions cannot be compiled" do
      file = %IR.File{path: "e.proto", syntax: {:edition, "2023"}}

      assert_raise ArgumentError, ~r/edition/, fn ->
        Compiler.quoted(ProtoFixtures.schema(file))
      end
    end

    test "invalid names are rejected before becoming atoms" do
      file = %IR.File{
        path: "x.proto",
        package: "x",
        messages: [
          %IR.Message{
            name: "A",
            full_name: "x.A",
            module: X.A,
            fields: [%IR.Field{name: "bad name", number: 1, type: :string}]
          }
        ]
      }

      assert_raise ArgumentError, ~r/invalid field name/, fn ->
        Compiler.quoted(ProtoFixtures.schema(file))
      end
    end
  end

  describe "compiled messages" do
    test "encode/decode roundtrip of every field kind" do
      user =
        struct!(mod(User),
          id: "u1",
          email: "a@b.c",
          role: :ROLE_ADMIN,
          tags: ["a", "b"],
          attributes: %{"k" => "v"},
          role_by_org: %{7 => :ROLE_USER},
          created_at: %Google.Protobuf.Timestamp{seconds: 10, nanos: 5},
          address:
            struct!(mod(User.Address), street: "Main", zip_code: "123", status: :STATUS_ACTIVE),
          contact: {:handle, "@u"},
          score: 1.5,
          legacy_id: 42,
          scores: [-1, 2, -3],
          addresses: %{"home" => struct!(mod(User.Address), street: "Home")},
          status: :STATUS_BANNED,
          avatar: <<0, 1, 2>>,
          counter: 99
        )

      binary = mod(User).encode(user)
      assert mod(User).decode(binary) == user
    end

    test "proto3 optional keeps presence, implicit fields default" do
      decoded = mod(User).decode(mod(User).encode(struct!(mod(User), [])))
      assert decoded.email == nil
      assert decoded.status == nil
      assert decoded.id == ""
      assert decoded.role == :ROLE_UNSPECIFIED

      decoded = mod(User).decode(mod(User).encode(struct!(mod(User), email: "")))
      assert decoded.email == ""
    end

    test "message props match the IR" do
      props = mod(User).__message_props__()
      assert props.syntax == :proto3

      by_name = Map.new(props.field_props, fn {_, p} -> {p.name, p} end)
      assert by_name["email"].proto3_optional?
      assert by_name["legacy_id"].json_name == "legacyID"
      assert by_name["created_at"].json_name == "createdAt"
      assert by_name["tags"].repeated?
      assert by_name["attributes"].map?
      assert by_name["role"].enum?
      assert by_name["score"].deprecated?
      assert by_name["phone"].oneof == 0
      assert props.oneof == [contact: 0]
      assert mod(User).full_name() == "acme.shop.v1.User"
    end

    test "proto2 messages keep labels and defaults" do
      item = Module.concat(AshGrpc.Test.CompilerTest.Legacy, Item)
      assert item.__message_props__().syntax == :proto2
      decoded = item.decode(item.encode(struct!(item, id: 1)))
      assert %{id: 1, name: "unnamed", price: 1.5, kind: :KIND_B, active: true} = decoded

      assert_raise Protobuf.EncodeError, fn -> item.encode(struct!(item, [])) end
    end

    test "enums", %{schema: _} do
      assert mod(Role).value(:ROLE_ADMIN) == 1
      assert mod(Role).key(2) == :ROLE_USER
      assert mod(Role).value(:ROLE_SUPERUSER) == 1
      assert mod(Role).full_name() == "acme.shop.v1.Role"
      assert mod(User.Status).value(:STATUS_BANNED) == 2
    end
  end

  describe "services" do
    test "service and stub" do
      service = mod(UserService.Service)
      assert service.__meta__(:name) == "acme.shop.v1.UserService"

      assert [
               {:GetUser, {get_req, false}, {user, false}, %{}},
               {:ListUsers, {_, false}, {_, true}, %{}},
               {:ImportUsers, {_, true}, {Google.Protobuf.Empty, false}, %{}},
               {:SyncUsers, {_, true}, {_, true}, %{}}
             ] = service.__rpc_calls__()

      assert get_req == mod(GetUserRequest)
      assert user == mod(User)

      stub = mod(UserService.Stub)
      assert function_exported?(stub, :get_user, 3)
      assert function_exported?(stub, :sync_users, 2)
    end

    test "stub_module/1" do
      assert Compiler.stub_module(A.B.Service) == A.B.Stub
      assert Compiler.stub_module(A.BService) == A.BService.Stub
      assert Compiler.stub_module(Service) == Service.Stub
    end
  end

  describe "descriptors" do
    test "every module exposes its descriptor" do
      assert %Google.Protobuf.DescriptorProto{name: "User"} = user = mod(User).descriptor()

      assert Enum.map(user.nested_type, & &1.name) == [
               "AttributesEntry",
               "RoleByOrgEntry",
               "AddressesEntry",
               "Address"
             ]

      assert Enum.map(user.oneof_decl, & &1.name) == ["contact", "_email", "_status"]

      assert %Google.Protobuf.EnumDescriptorProto{name: "Role", options: %{allow_alias: true}} =
               mod(Role).descriptor()

      assert %Google.Protobuf.ServiceDescriptorProto{method: [get | _]} =
               mod(UserService.Service).descriptor()

      assert get.input_type == ".acme.shop.v1.GetUserRequest"
      assert get.options.idempotency_level == :NO_SIDE_EFFECTS
      assert mod(User.AttributesEntry).descriptor().options.map_entry
    end

    test "file descriptor set", %{schema: schema} do
      %Google.Protobuf.FileDescriptorSet{file: [shop, legacy]} =
        Compiler.file_descriptor_set(schema)

      assert shop.name == "acme/shop/v1/shop.proto"
      assert shop.syntax == "proto3"
      assert shop.options.go_package == "github.com/acme/shop/gen/v1;shopv1"
      assert shop.options.optimize_for == :SPEED

      assert shop.dependency == [
               "acme/toolkit/v1/options.proto",
               "google/protobuf/empty.proto",
               "google/protobuf/timestamp.proto"
             ]

      assert legacy.syntax == nil

      # the descriptor survives a protobuf roundtrip
      binary = Google.Protobuf.FileDescriptorSet.encode(Compiler.file_descriptor_set(schema))

      assert Google.Protobuf.FileDescriptorSet.decode(binary) ==
               Compiler.file_descriptor_set(schema)
    end

    test "grpc_reflection can build a reflection tree" do
      assert {:ok, %GrpcReflection.Service.State{} = state} =
               GrpcReflection.Service.Builder.build_reflection_tree([mod(UserService.Service)])

      assert Map.has_key?(state.symbols, "acme.shop.v1.UserService")
      assert Map.has_key?(state.symbols, "acme.shop.v1.User")
    end
  end

  describe "compile/2" do
    test "is idempotent and recompiles changed definitions" do
      file = %IR.File{
        path: "idem/v1/idem.proto",
        package: "idem.v1",
        messages: [
          %IR.Message{
            name: "Thing",
            full_name: "idem.v1.Thing",
            module: AshGrpc.Test.CompilerTest.Idem.Thing,
            fields: [%IR.Field{name: "a", number: 1, type: :string}]
          }
        ]
      }

      thing = AshGrpc.Test.CompilerTest.Idem.Thing
      assert [^thing] = Compiler.compile(ProtoFixtures.schema(file))
      md5 = thing.module_info(:md5)

      assert [^thing] = Compiler.compile(ProtoFixtures.schema(file))
      assert thing.module_info(:md5) == md5

      [message] = file.messages

      changed = %{
        message
        | fields: message.fields ++ [%IR.Field{name: "b", number: 2, type: :int32}]
      }

      Compiler.compile(ProtoFixtures.schema(%{file | messages: [changed]}))
      assert thing.module_info(:md5) != md5
      assert %{b: 0} = struct!(thing, [])
    end

    test "keeps modules that were not compiled by AshGrpc" do
      file = %IR.File{
        path: "google/protobuf/duration.proto",
        package: "google.protobuf",
        messages: [
          %IR.Message{
            name: "Duration",
            full_name: "google.protobuf.Duration",
            module: Google.Protobuf.Duration,
            fields: [%IR.Field{name: "other", number: 1, type: :string}]
          }
        ]
      }

      md5 = Google.Protobuf.Duration.module_info(:md5)
      assert [Google.Protobuf.Duration] = Compiler.compile(ProtoFixtures.schema(file))
      assert Google.Protobuf.Duration.module_info(:md5) == md5
    end

    test "modules default to the protoc-gen-elixir naming convention" do
      file = %IR.File{
        path: "conv/v1/conv.proto",
        package: "ash_grpc_conv.v1",
        messages: [
          %IR.Message{
            name: "Thing",
            full_name: "ash_grpc_conv.v1.Thing",
            fields: [
              %IR.Field{name: "date", number: 1, type: {:message, "google.type.Date"}},
              %IR.Field{name: "ext", number: 2, type: {:message, "other.Ext"}}
            ]
          }
        ]
      }

      schema = ProtoFixtures.schema(file)
      assert [AshGrpcConv.V1.Thing] = Compiler.compile(schema, modules: %{"other.Ext" => My.Ext})
      props = Module.concat(AshGrpcConv.V1, Thing).__message_props__().field_props
      assert props[1].type == Google.Type.Date
      assert props[2].type == My.Ext
      assert Compiler.module_for(schema, "google.protobuf.Empty") == Google.Protobuf.Empty
    end
  end

  describe "to_source/2" do
    test "produces formatted source that compiles to equivalent modules" do
      prefix = AshGrpc.Test.CompilerTest.Source.V1
      schema = ProtoFixtures.schema(ProtoFixtures.shop_file(prefix))

      assert [{"acme/shop/v1/shop.pb.ex", source}] = Compiler.to_source(schema)

      assert source ==
               IO.iodata_to_binary([
                 Code.format_string!(source,
                   locals_without_parens: [field: 2, field: 3, oneof: 2, rpc: 3]
                 ),
                 "\n"
               ])

      assert source =~ "defmodule AshGrpc.Test.CompilerTest.Source.V1.User do"
      assert source =~ ~s(field :legacy_id, 12, type: :int64, json_name: "legacyID")
      assert source =~ ~s(field :email, 2, proto3_optional: true, type: :string)

      assert source =~
               ~r/rpc :ListUsers,\s+AshGrpc.Test.CompilerTest.Source.V1.ListUsersRequest,\s+stream\(AshGrpc.Test.CompilerTest.Source.V1.User\)/

      assert source =~ "# credo:disable-for-next-line"

      modules = source |> Code.compile_string() |> Enum.map(&elem(&1, 0))
      user = Module.concat(prefix, User)
      assert user in modules
      assert user.descriptor() == mod(User).descriptor()

      value = struct!(mod(User), id: "x", tags: ["t"], contact: {:phone, "1"})

      assert user.decode(mod(User).encode(value)) ==
               struct!(user, id: "x", tags: ["t"], contact: {:phone, "1"})
    end
  end
end
