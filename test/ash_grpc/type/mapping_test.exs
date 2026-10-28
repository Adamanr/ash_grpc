defmodule AshGrpc.Type.MappingTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.IR
  alias AshGrpc.Test.Types
  alias AshGrpc.Type.Mapping
  alias AshGrpc.Type.Mapping.Result

  doctest AshGrpc.Type.Naming

  test "nullable scalars get explicit presence" do
    assert {:ok, %Result{type: :string, label: :optional}} = Mapping.to_proto(:string)

    assert {:ok, %Result{type: :int64, label: nil}} =
             Mapping.to_proto(:integer, [], allow_nil?: false)
  end

  test "arrays are repeated" do
    assert {:ok, %Result{type: :string, label: :repeated}} = Mapping.to_proto({:array, :string})
  end

  test "datetimes map to Timestamp and add the import" do
    assert {:ok,
            %Result{
              type: {:message, "google.protobuf.Timestamp"},
              imports: ["google/protobuf/timestamp.proto"]
            }} =
             Mapping.to_proto(:utc_datetime_usec)
  end

  describe "default table" do
    for {type, proto, import} <- [
          {:string, :string, nil},
          {:ci_string, :string, nil},
          {:integer, :int64, nil},
          {:float, :double, nil},
          {:decimal, :string, nil},
          {:boolean, :bool, nil},
          {:uuid, :string, nil},
          {:uuid_v7, :string, nil},
          {:binary, :bytes, nil},
          {:url_encoded_binary, :bytes, nil},
          {:atom, :string, nil},
          {:module, :string, nil},
          {:naive_datetime, :string, nil},
          {:date, {:message, "google.type.Date"}, "google/type/date.proto"},
          {:time, {:message, "google.type.TimeOfDay"}, "google/type/timeofday.proto"},
          {:time_usec, {:message, "google.type.TimeOfDay"}, "google/type/timeofday.proto"},
          {:utc_datetime, {:message, "google.protobuf.Timestamp"},
           "google/protobuf/timestamp.proto"},
          {:datetime, {:message, "google.protobuf.Timestamp"}, "google/protobuf/timestamp.proto"},
          {:duration, {:message, "google.protobuf.Duration"}, "google/protobuf/duration.proto"},
          {:map, {:message, "google.protobuf.Struct"}, "google/protobuf/struct.proto"},
          {:struct, {:message, "google.protobuf.Struct"}, "google/protobuf/struct.proto"},
          {:keyword, {:message, "google.protobuf.Struct"}, "google/protobuf/struct.proto"}
        ] do
      test "#{inspect(type)} → #{inspect(proto)}" do
        assert {:ok, %Result{type: unquote(Macro.escape(proto)), imports: imports}} =
                 Mapping.to_proto(unquote(type), [], allow_nil?: false)

        assert imports == List.wrap(unquote(import))
      end
    end

    test "messages never get a label, nullable or not" do
      assert {:ok, %Result{label: nil}} = Mapping.to_proto(:date)
      assert {:ok, %Result{label: nil}} = Mapping.to_proto(:date, [], allow_nil?: false)
    end

    test "vector is repeated float" do
      assert {:ok, %Result{type: :float, label: :repeated}} = Mapping.to_proto(:vector)
    end

    test "unsupported types are errors" do
      for type <- [:term, :function, :file, :tuple] do
        assert {:error, {:unsupported, _, _}} = Mapping.to_proto(type), inspect(type)
      end
    end

    test "unknown modules are errors" do
      assert {:error, _} = Mapping.to_proto(String)
    end
  end

  describe "representations" do
    test "integer representations" do
      for rep <- ~w(int32 sint64 sint32 sfixed64 sfixed32 uint64 uint32 fixed64 fixed32 string)a do
        assert {:ok, %Result{type: ^rep, label: :optional}} =
                 Mapping.to_proto(:integer, [], representation: rep)
      end

      assert {:ok,
              %Result{
                type: {:message, "google.protobuf.Int32Value"},
                label: nil,
                imports: imports
              }} =
               Mapping.to_proto(:integer, [],
                 representation: {:message, "google.protobuf.Int32Value"}
               )

      assert imports == ["google/protobuf/wrappers.proto"]
    end

    test "decimal can be google.type.Decimal but never a float" do
      assert {:ok,
              %Result{
                type: {:message, "google.type.Decimal"},
                imports: ["google/type/decimal.proto"]
              }} =
               Mapping.to_proto(:decimal, [], representation: {:message, "google.type.Decimal"})

      assert {:error, {:unsupported_representation, Ash.Type.Decimal, :double}} =
               Mapping.to_proto(:decimal, [], representation: :double)
    end

    test "uuid as bytes" do
      assert {:ok, %Result{type: :bytes}} = Mapping.to_proto(:uuid, [], representation: :bytes)
    end

    test "datetimes, dates and durations as strings" do
      for type <- [:utc_datetime, :date, :time, :duration] do
        assert {:ok, %Result{type: :string, imports: []}} =
                 Mapping.to_proto(type, [], representation: :string)
      end
    end

    test "maps, enums and terms" do
      assert {:ok, %Result{type: :string}} = Mapping.to_proto(:map, [], representation: :string)

      assert {:ok, %Result{type: :string}} =
               Mapping.to_proto(Types.Role, [], representation: :string)

      assert {:ok, %Result{type: {:message, "google.protobuf.Value"}}} =
               Mapping.to_proto(:term, [], representation: {:message, "google.protobuf.Value"})

      assert {:ok, %Result{type: :string}} =
               Mapping.to_proto(Types.Address, [], representation: :string)
    end

    test "incompatible representations are errors" do
      assert {:error, {:unsupported_representation, Ash.Type.Boolean, :string}} =
               Mapping.to_proto(:boolean, [], representation: :string)

      assert {:error, {:unsupported_representation, _, :int64}} =
               Mapping.to_proto(:function, [], representation: :int64)
    end

    test "representations apply to array items" do
      assert {:ok, %Result{type: :int32, label: :repeated}} =
               Mapping.to_proto({:array, :integer}, [], representation: :int32)
    end
  end

  describe "enums" do
    test "Ash.Type.Enum is named after the module, values prefixed, UNSPECIFIED = 0" do
      assert {:ok, %Result{type: {:enum, "pkg.Role"}, label: :optional, enums: [enum]}} =
               Mapping.to_proto(Types.Role, [], package: "pkg", name_hint: "Ignored")

      assert %IR.Enum{name: "Role", full_name: "pkg.Role", source: {:type, Types.Role, []}} = enum

      assert [
               {"ROLE_UNSPECIFIED", 0, nil, nil},
               {"ROLE_ADMIN", 1, :admin, "Full access"},
               {"ROLE_MEMBER", 2, :member, "Regular member"},
               {"ROLE_GUEST", 3, :guest, "Read only"}
             ] == Enum.map(enum.values, &{&1.name, &1.number, &1.source, &1.doc})
    end

    test "required enums use implicit presence" do
      assert {:ok, %Result{label: nil}} = Mapping.to_proto(Types.Role, [], allow_nil?: false)
    end

    test "anonymous atom one_of enums use the name hint" do
      assert {:ok, %Result{type: {:enum, "Color"}, enums: [enum]}} =
               Mapping.to_proto(:atom, [one_of: [:dark_red, :blue]], name_hint: "Color")

      assert ~w(COLOR_UNSPECIFIED COLOR_DARK_RED COLOR_BLUE) == Enum.map(enum.values, & &1.name)
    end

    test "anonymous enums need a name hint" do
      assert {:error, {:name_hint_required, Ash.Type.Atom}} =
               Mapping.to_proto(:atom, one_of: [:a])
    end

    test "NewTypes of atom one_of are named after the NewType" do
      assert {:ok, %Result{type: {:enum, "Status"}, enums: [%IR.Enum{name: "Status"}]}} =
               Mapping.to_proto(Types.Status)
    end

    test "value name collisions are errors" do
      assert {:error, {:enum_value_collision, "X", ["X_A_B"]}} =
               Mapping.to_proto(:atom, [one_of: [:a_b, :"a-b"]], name_hint: "X")
    end

    test "module_prefix sets the module" do
      assert {:ok, %Result{enums: [%IR.Enum{module: My.Proto.Role}]}} =
               Mapping.to_proto(Types.Role, [], module_prefix: My.Proto)
    end
  end

  describe "typed maps" do
    test "generate nested messages" do
      assert {:ok, %Result{type: {:message, "pkg.Address"}, label: nil} = result} =
               Mapping.to_proto(Types.Address, [], package: "pkg", name_hint: "Address")

      assert [address, geo] = result.messages
      assert address.source == {:type, Ash.Type.Map, address.source |> elem(2)}

      assert [
               {"street", 1, :string, nil},
               {"city", 2, :string, :optional},
               {"zip", 3, :int64, :optional},
               {"tags", 4, :string, :repeated},
               {"geo", 5, {:message, "pkg.AddressGeo"}, nil}
             ] == Enum.map(address.fields, &{&1.name, &1.number, &1.type, &1.label})

      assert {:field, :street, Ash.Type.String, _} = hd(address.fields).source
      assert geo.full_name == "pkg.AddressGeo"
      assert Enum.map(geo.fields, &{&1.name, &1.label}) == [{"lat", nil}, {"lng", nil}]
    end

    test "keyword, struct and tuple with fields" do
      fields = [a: [type: :string], b: [type: :date]]

      for type <- [:keyword, :struct, :tuple] do
        assert {:ok, %Result{type: {:message, "T"}, messages: [message], imports: imports}} =
                 Mapping.to_proto(type, [fields: fields], name_hint: "T")

        assert message.source == {:type, Ash.Type.get_type(type), [fields: fields]}
        assert Enum.map(message.fields, & &1.name) == ["a", "b"]
        assert imports == ["google/type/date.proto"]
      end
    end

    test "need a name hint" do
      assert {:error, {:name_hint_required, Ash.Type.Map}} =
               Mapping.to_proto(:map, fields: [a: [type: :string]])
    end

    test "errors in fields propagate" do
      assert {:error, {:unsupported, Ash.Type.Term, _}} =
               Mapping.to_proto(:map, [fields: [a: [type: :term]]], name_hint: "T")
    end

    test "field name collisions are errors" do
      assert {:error, {:field_name_collision, "T", ["a_b"]}} =
               Mapping.to_proto(
                 :map,
                 [fields: [a_b: [type: :string], "a-b": [type: :string]]],
                 name_hint: "T"
               )
    end
  end

  describe "unions" do
    @types [
      text: [type: :string],
      number: [type: :integer, constraints: [max: 10]],
      role: [type: Types.Role],
      ints: [type: {:array, :integer}],
      vec: [type: :vector]
    ]

    test "a wrapper message with a oneof" do
      assert {:ok, %Result{type: {:message, "Content"}, enums: [%IR.Enum{name: "Role"}]} = result} =
               Mapping.to_proto(:union, [types: @types], name_hint: "Content")

      assert [content, ints, vec] = result.messages
      assert content.oneofs == [%IR.Oneof{name: "value"}]

      assert [
               {"text", 1, :string},
               {"number", 2, :int64},
               {"role", 3, {:enum, "Role"}},
               {"ints", 4, {:message, "ContentIntsList"}},
               {"vec", 5, {:message, "ContentVecItem"}}
             ] == Enum.map(content.fields, &{&1.name, &1.number, &1.type})

      assert Enum.all?(content.fields, &(&1.oneof == "value" and &1.label == nil))
      assert {:member, :number, Ash.Type.Integer, [max: 10]} = Enum.at(content.fields, 1).source
      assert {:list_wrapper, {:array, Ash.Type.Integer}, []} = ints.source
      assert {:item_wrapper, Ash.Type.Vector, []} = vec.source
      assert [%IR.Field{name: "value", label: :repeated, type: :float}] = vec.fields
    end
  end

  describe "arrays" do
    test "nil items are wrapped" do
      assert {:ok, %Result{type: {:message, "LabelsItem"}, label: :repeated, messages: [item]}} =
               Mapping.to_proto({:array, :string}, [nil_items?: true], name_hint: "Labels")

      assert %IR.Message{
               source: {:item_wrapper, :string, []},
               fields: [
                 %IR.Field{name: "value", number: 1, type: :string, label: :optional}
               ]
             } = item
    end

    test "nested arrays are wrapped per depth" do
      assert {:ok, %Result{type: {:message, "MList"}, label: :repeated, messages: [list]}} =
               Mapping.to_proto({:array, {:array, :integer}}, [], name_hint: "M")

      assert [%IR.Field{name: "values", type: :int64, label: :repeated}] = list.fields

      assert {:ok, %Result{type: {:message, "MListList"}, label: :repeated, messages: messages}} =
               Mapping.to_proto({:array, {:array, {:array, :integer}}}, [], name_hint: "M")

      assert ["MListList", "MList"] == Enum.map(messages, & &1.name)
    end

    test "distinguish_nil? wraps the whole list" do
      assert {:ok, %Result{type: {:message, "SList"}, label: nil, messages: [list]}} =
               Mapping.to_proto({:array, :integer}, [], name_hint: "S", distinguish_nil?: true)

      assert {:list_wrapper, {:array, :integer}, []} = list.source

      # required lists don't need it
      assert {:ok, %Result{type: :int64, label: :repeated}} =
               Mapping.to_proto({:array, :integer}, [],
                 name_hint: "S",
                 distinguish_nil?: true,
                 allow_nil?: false
               )
    end

    test "arrays of enums, typed maps and unions" do
      assert {:ok, %Result{type: {:enum, "Role"}, label: :repeated}} =
               Mapping.to_proto({:array, Types.Role})

      assert {:ok, %Result{type: {:message, "A"}, label: :repeated}} =
               Mapping.to_proto({:array, Types.Address}, [], name_hint: "A")
    end

    test "arrays of vectors wrap the items" do
      assert {:ok, %Result{type: {:message, "VItem"}, label: :repeated}} =
               Mapping.to_proto({:array, :vector}, [], name_hint: "V")
    end
  end

  describe "resources" do
    test "embedded resources are resolved by the builder" do
      resolve = fn Types.Profile -> "pkg.Profile" end

      assert {:ok, %Result{type: {:message, "pkg.Profile"}, label: nil}} =
               Mapping.to_proto(Types.Profile, [], resolve_resource: resolve)

      assert {:ok, %Result{type: {:message, "pkg.Profile"}, label: :repeated}} =
               Mapping.to_proto({:array, Types.Profile}, [], resolve_resource: resolve)

      assert {:ok, %Result{type: {:message, "pkg.Profile"}}} =
               Mapping.to_proto(:struct, [instance_of: Types.Profile],
                 resolve_resource: fn _ -> {:ok, "pkg.Profile"} end
               )
    end

    test "without a resolver they are errors" do
      assert {:error, {:unsupported, Types.Profile, _}} = Mapping.to_proto(Types.Profile)

      assert {:error, {:unresolved_resource, Types.Profile, nil}} =
               Mapping.to_proto(Types.Profile, [], resolve_resource: fn _ -> nil end)
    end

    test "structs of other modules without fields are Structs" do
      assert {:ok, %Result{type: {:message, "google.protobuf.Struct"}}} =
               Mapping.to_proto(:struct, instance_of: URI)
    end
  end

  describe "AshGrpc.Type" do
    test "custom types decide their mapping" do
      assert {:ok,
              %Result{type: {:message, "google.type.Money"}, imports: ["google/type/money.proto"]}} =
               Mapping.to_proto(Types.Money)

      assert {:ok, %Result{type: {:message, "google.protobuf.StringValue"}, imports: imports}} =
               Mapping.to_proto(Types.Slug)

      assert imports == ["google/protobuf/wrappers.proto"]
    end
  end

  describe "the test schema" do
    # every generated definition must match the hand-written protobuf modules
    test "matches the hand-written protobuf modules" do
      {schema, _record} = Types.Schema.build()
      [file] = schema.files

      assert Enum.sort(file.imports) == [
               "google/protobuf/duration.proto",
               "google/protobuf/struct.proto",
               "google/protobuf/timestamp.proto",
               "google/protobuf/wrappers.proto",
               "google/type/date.proto",
               "google/type/decimal.proto",
               "google/type/money.proto",
               "google/type/timeofday.proto"
             ]

      for enum <- file.enums do
        assert enum.module.full_name() == enum.full_name

        assert Map.new(enum.values, &{String.to_atom(&1.name), &1.number}) ==
                 enum.module.mapping()
      end

      for message <- file.messages do
        assert message.module.full_name() == message.full_name
        props = message.module.__message_props__()

        assert Enum.sort(Enum.map(message.fields, & &1.number)) ==
                 Enum.sort(Map.keys(props.field_props)),
               message.full_name

        for field <- message.fields do
          prop = Map.fetch!(props.field_props, field.number)
          assert prop.name == field.name, "#{message.full_name}.#{field.name}"

          assert prop.repeated? == (field.label == :repeated),
                 "#{message.full_name}.#{field.name}"

          assert prop.proto3_optional? == (field.label == :optional),
                 "#{message.full_name}.#{field.name}"

          assert prop.oneof != nil == (field.oneof != nil)
          assert_type(prop, field.type, schema)
        end
      end
    end
  end

  defp assert_type(prop, scalar, _schema) when is_atom(scalar), do: assert(prop.type == scalar)

  defp assert_type(prop, {:enum, full_name}, schema) do
    {:ok, enum} = IR.Schema.lookup(schema, full_name)
    assert prop.type == {:enum, enum.module}
  end

  defp assert_type(prop, {:message, full_name}, schema) do
    module =
      case IR.Schema.lookup(schema, full_name) do
        {:ok, message} -> message.module
        :error -> AshGrpc.Type.Known.module(full_name) || Google.Type.Money
      end

    assert prop.type == module
  end
end
