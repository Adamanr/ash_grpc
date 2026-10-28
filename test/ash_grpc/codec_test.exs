defmodule AshGrpc.CodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshGrpc.Codec
  alias AshGrpc.Proto.IR
  alias AshGrpc.Test.Types
  alias AshGrpc.Test.Types.Proto

  setup_all do
    {schema, record} = Types.Schema.build()
    %{schema: schema, record_message: record}
  end

  defp uuid, do: Ash.UUID.generate()

  defp sample do
    %{
      id: uuid(),
      name: "Ann",
      count: 3,
      ratio: 1.5,
      price: Decimal.new("12.30"),
      active: true,
      born_on: ~D[1990-01-02],
      wakes_at: ~T[07:30:00.123456],
      inserted_at: ~U[2024-01-02 03:04:05.123456Z],
      local_at: ~N[2024-01-02 03:04:05],
      ttl: Duration.new!(second: 3605, microsecond: {500_000, 6}),
      role: :admin,
      status: :archived,
      kind: :large,
      meta: %{"a" => 1, "b" => [true, nil, "x"], "c" => %{"d" => 1.5}},
      payload: [1, "two"],
      address: %{street: "Main", city: nil, zip: 12_345, tags: ["a"], geo: %{lat: 1.0, lng: 2.5}},
      content: %Ash.Union{type: :ints, value: [1, 2]},
      labels: ["a", nil, "c"],
      matrix: [[1, 2], [], [3]],
      scores: [],
      tags: ["x", "y"],
      profile: struct(Types.Profile, bio: "hi", role: :member, birthday: ~D[2000-01-01]),
      profiles: [struct(Types.Profile, bio: nil, role: nil, birthday: nil)],
      money: %{currency: "EUR", amount: Decimal.new("12.5")},
      slug: "my-slug",
      raw_id: uuid(),
      exact: Decimal.new("1.000"),
      big: 2 ** 62,
      small: 12,
      module: String
    }
  end

  defp field(record_message, name),
    do: Enum.find(record_message.fields, &(&1.name == to_string(name)))

  # encode → wire → decode
  defp wire_roundtrip(record, %{schema: schema, record_message: message}) do
    assert {:ok, %Proto.Record{} = struct} = Codec.encode_record(record, message, schema)
    decoded_struct = struct |> Proto.Record.encode() |> Proto.Record.decode()
    assert {:ok, map} = Codec.decode_message(decoded_struct, message, schema)
    {struct, map}
  end

  describe "encode_record/4" do
    test "produces protobuf-elixir values for every mapping", ctx do
      record = sample()

      assert {:ok, %Proto.Record{} = s} =
               Codec.encode_record(record, ctx.record_message, ctx.schema)

      assert s.id == record.id
      assert s.price == "12.30"
      assert s.born_on == %Google.Type.Date{year: 1990, month: 1, day: 2}

      assert s.wakes_at == %Google.Type.TimeOfDay{
               hours: 7,
               minutes: 30,
               seconds: 0,
               nanos: 123_456_000
             }

      assert s.inserted_at == %Google.Protobuf.Timestamp{
               seconds: 1_704_164_645,
               nanos: 123_456_000
             }

      assert s.local_at == "2024-01-02T03:04:05"
      assert s.ttl == %Google.Protobuf.Duration{seconds: 3605, nanos: 500_000_000}
      assert s.role == :ROLE_ADMIN
      assert s.status == :STATUS_ARCHIVED
      assert s.kind == :RECORD_KIND_LARGE
      assert %Google.Protobuf.Struct{fields: %{"a" => %{kind: {:number_value, 1.0}}}} = s.meta

      assert s.payload == %Google.Protobuf.Value{
               kind:
                 {:list_value,
                  %Google.Protobuf.ListValue{
                    values: [
                      %Google.Protobuf.Value{kind: {:number_value, 1.0}},
                      %Google.Protobuf.Value{kind: {:string_value, "two"}}
                    ]
                  }}
             }

      assert s.address == %Proto.Address{
               street: "Main",
               city: nil,
               zip: 12_345,
               tags: ["a"],
               geo: %Proto.AddressGeo{lat: 1.0, lng: 2.5}
             }

      assert s.content == %Proto.Content{value: {:ints, %Proto.ContentIntsList{values: [1, 2]}}}

      assert s.labels == [
               %Proto.LabelsItem{value: "a"},
               %Proto.LabelsItem{value: nil},
               %Proto.LabelsItem{value: "c"}
             ]

      assert s.matrix == [
               %Proto.MatrixList{values: [1, 2]},
               %Proto.MatrixList{values: []},
               %Proto.MatrixList{values: [3]}
             ]

      assert s.scores == %Proto.ScoresList{values: []}

      assert s.profile == %Proto.Profile{
               bio: "hi",
               role: :ROLE_MEMBER,
               birthday: %Google.Type.Date{year: 2000, month: 1, day: 1}
             }

      assert s.profiles == [%Proto.Profile{}]
      assert s.money == %Google.Type.Money{currency_code: "EUR", units: 12, nanos: 500_000_000}
      assert s.slug == %Google.Protobuf.StringValue{value: "my-slug"}
      assert byte_size(s.raw_id) == 16
      assert s.exact == %Google.Type.Decimal{value: "1.000"}
      assert s.big == "4611686018427387904"
      assert s.small == 12
      assert s.module == "String"
    end

    test "nil values stay absent", ctx do
      assert {:ok, s} = Codec.encode_record(%{id: uuid()}, ctx.record_message, ctx.schema)
      assert s.name == nil
      assert s.role == nil
      assert s.address == nil
      assert s.scores == nil
      assert s.labels == []
      assert s.content == nil
      assert s.active == false
    end

    test "not loaded and forbidden values are skipped", ctx do
      record = %{id: uuid(), name: %Ash.NotLoaded{}, count: %Ash.ForbiddenField{}}

      assert {:ok, %{name: nil, count: nil}} =
               Codec.encode_record(record, ctx.record_message, ctx.schema)
    end

    test "keyword lists work as records", ctx do
      assert {:ok, %{name: "x"}} =
               Codec.encode_record([name: "x"], ctx.record_message, ctx.schema)
    end

    test "errors carry the path", ctx do
      record = %{sample() | address: %{sample().address | geo: %{lat: "north", lng: 1.0}}}

      assert {:error, {:invalid_value, "north", :double, _, ["address", "geo", "lat"]}} =
               Codec.encode_record(record, ctx.record_message, ctx.schema)

      assert {:error, {:invalid_value, 2_147_483_648, :int32, "out of range", ["small"]}} =
               Codec.encode_record(%{small: 2_147_483_648}, ctx.record_message, ctx.schema)

      assert {:error, {:invalid_value, nil, :string, _, ["tags", 1]}} =
               Codec.encode_record(%{tags: ["a", nil]}, ctx.record_message, ctx.schema)

      assert {:error, {:invalid_value, :owner, "test.types.v1.Role", _, ["role"]}} =
               Codec.encode_record(%{role: :owner}, ctx.record_message, ctx.schema)
    end

    test "messages without a module are errors" do
      message = %IR.Message{name: "X", full_name: "x.X", fields: []}
      assert {:error, {:no_module, "x.X"}} = Codec.encode_record(%{}, message, nil)
    end

    test "nil records are nil", ctx do
      assert {:ok, nil} = Codec.encode_record(nil, ctx.record_message, ctx.schema)
      assert {:ok, nil} = Codec.decode_message(nil, ctx.record_message, ctx.schema)
    end
  end

  describe "decode_message/4" do
    test "roundtrips every mapping over the wire and Ash casts the result", ctx do
      record = sample()
      {_struct, map} = wire_roundtrip(record, ctx)

      for {name, type, constraints, _opts} <- Types.Schema.fields() do
        original = Map.fetch!(record, name)
        {:ok, constraints} = Ash.Type.init(type, constraints)

        case original do
          nil ->
            refute Map.has_key?(map, name), "#{name} should be absent"

          _ ->
            assert {:ok, cast} = Ash.Type.cast_input(type, Map.fetch!(map, name), constraints),
                   "#{name}: #{inspect(Map.get(map, name))}"

            assert_same(name, original, cast)
        end
      end
    end

    test "absent optional fields are skipped, implicit ones are kept", ctx do
      {_struct, map} = wire_roundtrip(%{id: uuid()}, ctx)

      assert Map.keys(map) |> Enum.sort() == [:active, :id]
      assert map.active == false
    end

    test "UNSPECIFIED enums decode to nil", ctx do
      struct = %Proto.Record{role: :ROLE_UNSPECIFIED}
      assert {:ok, %{role: nil}} = Codec.decode_message(struct, ctx.record_message, ctx.schema)
    end

    test "unknown enum numbers are errors", ctx do
      struct = %Proto.Record{role: 42}

      assert {:error, {:invalid_value, 42, "test.types.v1.Role", "unknown enum value", ["role"]}} =
               Codec.decode_message(struct, ctx.record_message, ctx.schema)
    end

    test ":present forces fields (update masks)", ctx do
      assert {:ok, map} =
               Codec.decode_message(%Proto.Record{}, ctx.record_message, ctx.schema,
                 present: ["name", "tags", "content"]
               )

      assert map == %{id: "", active: false, name: nil, tags: [], content: nil}
    end

    test "nested typed maps skip absent optional fields", ctx do
      struct = %Proto.Record{address: %Proto.Address{street: "s"}}

      assert {:ok, %{address: address}} =
               Codec.decode_message(struct, ctx.record_message, ctx.schema)

      assert address == %{street: "s"}
    end

    test "invalid values are errors", ctx do
      struct = %Proto.Record{born_on: %Google.Type.Date{year: 2020, month: 0, day: 0}}

      assert {:error, {:invalid_value, _, "google.type.Date", _, ["born_on"]}} =
               Codec.decode_message(struct, ctx.record_message, ctx.schema)

      assert {:error, {:invalid_value, "abc", :string, "invalid integer", ["big"]}} =
               Codec.decode_message(%Proto.Record{big: "abc"}, ctx.record_message, ctx.schema)

      assert {:error, {:invalid_value, :nope, _, _}} =
               Codec.decode_message(:nope, ctx.record_message, ctx.schema)
    end
  end

  describe "field sources" do
    test "resource lookups for {kind, name} and bare atoms", ctx do
      {:ok, profile} = IR.Schema.lookup(ctx.schema, "test.types.v1.Profile")
      record = struct(Types.Profile, bio: "b", role: :guest, birthday: ~D[2001-02-03])

      assert {:ok, %Proto.Profile{role: :ROLE_GUEST} = struct} =
               Codec.encode_record(record, profile, ctx.schema)

      assert {:ok, %{bio: "b", role: :guest, birthday: ~D[2001-02-03]}} =
               Codec.decode_message(struct, profile, ctx.schema)
    end

    test "nil sources use the proto field name and natural conversions" do
      message = %IR.Message{
        name: "Address",
        full_name: "test.types.v1.Address",
        module: Proto.Address,
        fields: [
          %IR.Field{name: "street", number: 1, type: :string},
          %IR.Field{name: "zip", number: 3, type: :int64, label: :optional}
        ]
      }

      assert {:ok, %Proto.Address{street: "s", zip: 1}} =
               Codec.encode_record(%{street: "s", zip: 1}, message, nil)

      assert {:ok, %{street: "s", zip: 1}} =
               Codec.decode_message(%Proto.Address{street: "s", zip: 1}, message, nil)
    end

    test "{:skip, _} sources are ignored" do
      message = %IR.Message{
        name: "Address",
        full_name: "test.types.v1.Address",
        module: Proto.Address,
        fields: [%IR.Field{name: "street", number: 1, type: :string, source: {:skip, :token}}]
      }

      assert {:ok, %Proto.Address{street: ""}} = Codec.encode_record(%{token: "x"}, message, nil)
      assert {:ok, %{}} = Codec.decode_message(%Proto.Address{street: "x"}, message, nil)
    end

    test "unsupported sources are errors" do
      message = %IR.Message{
        name: "Address",
        full_name: "test.types.v1.Address",
        module: Proto.Address,
        fields: [%IR.Field{name: "street", number: 1, type: :string, source: "street"}]
      }

      assert {:error, {:unsupported_field_source, "street", "street"}} =
               Codec.encode_record(%{}, message, nil)
    end
  end

  describe "encode/5 and decode/5" do
    test "enums without a schema follow the naming convention" do
      assert {:ok, :ROLE_GUEST} = Codec.encode(:guest, Types.Role, [], {:enum, "pkg.Role"})
      assert {:ok, :guest} = Codec.decode(:ROLE_GUEST, Types.Role, [], {:enum, "pkg.Role"})
      assert {:ok, nil} = Codec.decode(:ROLE_UNSPECIFIED, Types.Role, [], {:enum, "pkg.Role"})
      assert {:ok, nil} = Codec.decode(0, Types.Role, [], {:enum, "pkg.Role"})
      assert {:error, _} = Codec.decode(:ROLE_OWNER, Types.Role, [], {:enum, "pkg.Role"})
      assert {:error, _} = Codec.decode(7, Types.Role, [], {:enum, "pkg.Role"})
      assert {:error, _} = Codec.encode(:owner, Types.Role, [], {:enum, "pkg.Role"})
    end

    test "enums as strings never create atoms" do
      assert {:ok, "admin"} = Codec.encode(:admin, Types.Role, [], :string)
      assert {:ok, :admin} = Codec.decode("admin", Types.Role, [], :string)

      assert {:error, _} =
               Codec.decode("never_seen_atom_#{System.unique_integer()}", Types.Role, [], :string)

      assert {:ok, nil} = Codec.decode("", Types.Role, [], :string)
    end

    test "the lock may renumber enums: schema values win", ctx do
      {:ok, enum} = IR.Schema.lookup(ctx.schema, "test.types.v1.Role")
      enum = %{enum | values: Enum.map(enum.values, &%{&1 | number: &1.number * 10})}
      [file] = ctx.schema.files
      schema = %IR.Schema{files: [%{file | enums: [enum]}]}

      assert {:ok, :admin} =
               Codec.decode(10, Types.Role, [], {:enum, "test.types.v1.Role"}, schema: schema)

      assert {:ok, :ROLE_ADMIN} =
               Codec.encode(:admin, Types.Role, [], {:enum, "test.types.v1.Role"}, schema: schema)
    end

    test "wrappers" do
      wrapper = {:message, "google.protobuf.Int64Value"}
      assert {:ok, %Google.Protobuf.Int64Value{value: 5}} = Codec.encode(5, :integer, [], wrapper)
      assert {:ok, 5} = Codec.decode(%Google.Protobuf.Int64Value{value: 5}, :integer, [], wrapper)
      assert {:ok, nil} = Codec.encode(nil, :integer, [], wrapper)
      assert {:ok, nil} = Codec.decode(nil, :integer, [], wrapper)
    end

    test "durations with months are rejected" do
      assert {:error, {:invalid_value, _, "google.protobuf.Duration", _}} =
               Codec.encode(
                 Duration.new!(month: 1),
                 :duration,
                 [],
                 {:message, "google.protobuf.Duration"}
               )
    end

    test "string representations of temporal values" do
      for {type, value} <- [
            utc_datetime_usec: ~U[2024-01-02 03:04:05.123456Z],
            date: ~D[2024-01-02],
            time: ~T[01:02:03],
            duration: Duration.new!(hour: 1, minute: 2),
            float: 1.25,
            integer: -7,
            decimal: Decimal.new("-1.50")
          ] do
        assert {:ok, string} = Codec.encode(value, type, [], :string)
        assert is_binary(string)
        assert {:ok, ^value} = Codec.decode(string, type, [], :string)
      end
    end

    test "maps as JSON strings" do
      value = %{"a" => [1, %{"b" => nil}], "c" => "d"}
      assert {:ok, json} = Codec.encode(value, :map, [], :string)
      assert {:ok, ^value} = Codec.decode(json, :map, [], :string)
    end

    test "Struct normalizes atoms, decimals and dates" do
      value = %{a: :b, c: Decimal.new("1.5"), d: ~D[2024-01-01], e: {1, 2}, f: [k: 1]}
      assert {:ok, struct} = Codec.encode(value, :map, [], {:message, "google.protobuf.Struct"})

      assert {:ok,
              %{"a" => "b", "c" => "1.5", "d" => "2024-01-01", "e" => [1, 2], "f" => %{"k" => 1}}} =
               Codec.decode(struct, :map, [], {:message, "google.protobuf.Struct"})

      assert {:error, _} =
               Codec.encode(%{a: self()}, :map, [], {:message, "google.protobuf.Struct"})

      assert {:error, _} =
               Codec.encode(%{a: <<255>>}, :map, [], {:message, "google.protobuf.Struct"})
    end

    test "tuples and keywords with fields", ctx do
      fields = [a: [type: :string], b: [type: :integer]]

      {:ok, result} =
        AshGrpc.Type.Mapping.to_proto(:tuple, [fields: fields],
          name_hint: "Pair",
          package: "test.types.v1",
          module_prefix: Proto
        )

      [file] = ctx.schema.files
      schema = %IR.Schema{files: [%{file | messages: result.messages}]}

      assert {:ok, %Proto.Pair{a: "x", b: 1} = pair} =
               Codec.encode({"x", 1}, :tuple, [fields: fields], result.type, schema: schema)

      assert {:ok, {"x", 1}} =
               Codec.decode(pair, :tuple, [fields: fields], result.type, schema: schema)

      assert {:ok, [a: "x", b: 1]} =
               Codec.decode(pair, :keyword, [fields: fields], result.type, schema: schema)

      assert {:ok, %Proto.Pair{a: "x"}} =
               Codec.encode([a: "x"], :keyword, [fields: fields], result.type, schema: schema)

      assert {:error, _} =
               Codec.encode({"x"}, :tuple, [fields: fields], result.type, schema: schema)
    end

    test "generated messages need a schema" do
      assert {:error, {:unknown_message, "x.Y"}} =
               Codec.encode(%{a: 1}, :map, [fields: [a: [type: :integer]]], {:message, "x.Y"})
    end

    test "unions with unknown members are errors", ctx do
      constraints = [types: [text: [type: :string]]]
      field_type = {:message, "test.types.v1.Content"}

      assert {:error, {:invalid_value, :nope, _, _}} =
               Codec.encode(%Ash.Union{type: :nope, value: 1}, :union, constraints, field_type,
                 schema: ctx.schema
               )

      assert {:error, {:invalid_value, "raw", _, _}} =
               Codec.encode("raw", :union, constraints, field_type, schema: ctx.schema)

      assert {:ok, nil} =
               Codec.decode(%Proto.Content{}, :union, constraints, field_type, schema: ctx.schema)
    end

    test "uuid bytes" do
      id = uuid()
      assert {:ok, raw} = Codec.encode(id, :uuid, [], :bytes)
      assert {:ok, ^id} = Codec.decode(raw, :uuid, [], :bytes)
      assert {:ok, nil} = Codec.decode("", :uuid, [], :bytes)
      assert {:error, _} = Codec.encode("not-a-uuid", :uuid, [], :bytes)
    end

    test "vectors" do
      assert {:ok, [1.0, 2.0]} =
               Codec.encode(elem(Ash.Vector.new([1, 2]), 1), :vector, [], :float)

      assert {:ok, [1.0, 2.0]} = Codec.decode([1.0, 2.0], :vector, [], :float)
    end

    test "unknown ash types use natural conversions" do
      assert {:ok, %Google.Protobuf.Timestamp{}} =
               Codec.encode(
                 ~U[2024-01-01 00:00:00Z],
                 nil,
                 [],
                 {:message, "google.protobuf.Timestamp"}
               )

      assert {:ok, ~U[2024-01-01 00:00:00.000000Z]} =
               Codec.decode(
                 %Google.Protobuf.Timestamp{seconds: 1_704_067_200},
                 nil,
                 [],
                 {:message, "google.protobuf.Timestamp"}
               )

      assert {:ok, %{"k" => 1}} = Codec.decode(%{"k" => 1}, nil, [], {:map, :string, :int64})
      assert {:ok, %{"k" => 1}} = Codec.encode(%{"k" => 1}, nil, [], {:map, :string, :int64})
      assert {:ok, [1, 2]} = Codec.encode([1, 2], nil, [], :int64)
      assert {:ok, :FOO} = Codec.decode(:FOO, nil, [], {:enum, "x.Unknown"})
    end

    test "custom types without codec callbacks use the default codec" do
      wrapper = {:message, "google.protobuf.StringValue"}

      assert {:ok, %Google.Protobuf.StringValue{value: "s"}} =
               Codec.encode("s", Types.Slug, [], wrapper)

      assert {:ok, "s"} =
               Codec.decode(%Google.Protobuf.StringValue{value: "s"}, Types.Slug, [], wrapper)
    end
  end

  describe "properties" do
    property "integers roundtrip through every integer representation" do
      check all(
              value <- integer(-2_147_483_648..2_147_483_647),
              rep <- member_of([:int64, :int32, :sint64, :sint32, :sfixed32, :sfixed64, :string])
            ) do
        assert {:ok, encoded} = Codec.encode(value, :integer, [], rep)
        assert {:ok, ^value} = Codec.decode(encoded, :integer, [], rep)
      end
    end

    property "decimals roundtrip as strings and google.type.Decimal" do
      check all(
              int <- integer(),
              exp <- integer(-10..10),
              rep <- member_of([:string, {:message, "google.type.Decimal"}])
            ) do
        value = Decimal.new(if(int < 0, do: -1, else: 1), abs(int), exp)
        assert {:ok, encoded} = Codec.encode(value, :decimal, [], rep)
        assert {:ok, decoded} = Codec.decode(encoded, :decimal, [], rep)
        assert Decimal.equal?(decoded, value)
      end
    end

    property "timestamps roundtrip (microsecond precision) over the wire" do
      check all(us <- integer(-62_135_596_800_000_000..253_402_300_799_999_999)) do
        value = DateTime.from_unix!(us, :microsecond)
        type = {:message, "google.protobuf.Timestamp"}
        assert {:ok, ts} = Codec.encode(value, :utc_datetime_usec, [], type)
        ts = ts |> Google.Protobuf.Timestamp.encode() |> Google.Protobuf.Timestamp.decode()
        assert {:ok, decoded} = Codec.decode(ts, :utc_datetime_usec, [], type)
        assert DateTime.compare(decoded, value) == :eq
      end
    end

    property "dates and times roundtrip" do
      check all(days <- integer(0..3_000_000), us <- integer(0..86_399_999_999)) do
        date = Date.add(~D[0001-01-01], days)
        assert {:ok, d} = Codec.encode(date, :date, [], {:message, "google.type.Date"})
        assert {:ok, ^date} = Codec.decode(d, :date, [], {:message, "google.type.Date"})

        time = Time.from_seconds_after_midnight(div(us, 1_000_000), {rem(us, 1_000_000), 6})
        assert {:ok, t} = Codec.encode(time, :time_usec, [], {:message, "google.type.TimeOfDay"})
        assert {:ok, ^time} = Codec.decode(t, :time_usec, [], {:message, "google.type.TimeOfDay"})
      end
    end

    property "durations roundtrip" do
      check all(seconds <- integer(-1_000_000..1_000_000), us <- integer(0..999_999)) do
        sign = if seconds < 0, do: -1, else: 1
        value = Duration.new!(second: seconds, microsecond: {sign * us, 6})
        type = {:message, "google.protobuf.Duration"}
        assert {:ok, encoded} = Codec.encode(value, :duration, [], type)
        assert {:ok, decoded} = Codec.decode(encoded, :duration, [], type)
        assert to_us(decoded) == to_us(value)
      end
    end

    property "JSON-like maps roundtrip through Struct" do
      check all(value <- map_of(string(:alphanumeric), json_value(), max_length: 5)) do
        type = {:message, "google.protobuf.Struct"}
        assert {:ok, struct} = Codec.encode(value, :map, [], type)
        struct = struct |> Google.Protobuf.Struct.encode() |> Google.Protobuf.Struct.decode()
        assert {:ok, ^value} = Codec.decode(struct, :map, [], type)
      end
    end

    property "nullable string arrays roundtrip through item wrappers", ctx do
      message = ctx.record_message
      field = field(message, :labels)

      check all(labels <- list_of(one_of([constant(nil), string(:printable)]))) do
        assert {:ok, encoded} =
                 Codec.encode(labels, {:array, :string}, [nil_items?: true], field.type,
                   schema: ctx.schema
                 )

        assert {:ok, ^labels} =
                 Codec.decode(encoded, {:array, :string}, [nil_items?: true], field.type,
                   schema: ctx.schema
                 )
      end
    end

    property "nested integer arrays roundtrip", ctx do
      field = field(ctx.record_message, :matrix)
      type = {:array, {:array, :integer}}

      check all(matrix <- list_of(list_of(integer()))) do
        assert {:ok, encoded} = Codec.encode(matrix, type, [], field.type, schema: ctx.schema)
        assert {:ok, ^matrix} = Codec.decode(encoded, type, [], field.type, schema: ctx.schema)
      end
    end

    property "unions roundtrip", ctx do
      field = field(ctx.record_message, :content)
      {_, _, constraints, _} = Enum.find(Types.Schema.fields(), &(elem(&1, 0) == :content))

      member =
        one_of([
          map(string(:printable), &%Ash.Union{type: :text, value: &1}),
          map(integer(), &%Ash.Union{type: :number, value: &1}),
          map(list_of(integer()), &%Ash.Union{type: :ints, value: &1})
        ])

      check all(value <- member) do
        assert {:ok, encoded} =
                 Codec.encode(value, :union, constraints, field.type, schema: ctx.schema)

        assert {:ok, ^value} =
                 Codec.decode(encoded, :union, constraints, field.type, schema: ctx.schema)
      end
    end
  end

  defp json_value do
    leaf =
      one_of([
        constant(nil),
        boolean(),
        integer(-1_000_000..1_000_000),
        # whole floats decode as integers, so keep a fraction
        map(integer(-1_000_000..1_000_000), &(&1 + 0.25)),
        string(:printable)
      ])

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 3), map_of(string(:alphanumeric), child, max_length: 3)])
    end)
  end

  defp to_us(%Duration{second: s, microsecond: {us, _}}), do: s * 1_000_000 + us

  # compares an original value with the decoded + cast one
  defp assert_same(:profile, original, cast) do
    assert Map.take(cast, [:bio, :role, :birthday]) ==
             Map.take(original, [:bio, :role, :birthday])
  end

  defp assert_same(:profiles, original, cast) do
    Enum.zip(original, cast) |> Enum.each(fn {o, c} -> assert_same(:profile, o, c) end)
  end

  defp assert_same(:address, original, cast) do
    assert cast == Map.reject(original, fn {_, v} -> is_nil(v) end) |> Map.put(:city, nil) or
             cast == Map.reject(original, fn {_, v} -> is_nil(v) end)
  end

  defp assert_same(:money, original, cast) do
    assert cast.currency == original.currency
    assert Decimal.equal?(cast.amount, original.amount)
  end

  defp assert_same(name, %Decimal{} = original, cast),
    do: assert(Decimal.equal?(original, cast), "#{name}")

  defp assert_same(:ttl, original, cast), do: assert(to_us(original) == to_us(cast))
  defp assert_same(name, original, cast), do: assert(original == cast, "#{name}")
end
