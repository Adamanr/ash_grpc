defmodule AshGrpc.Proto.LockTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.{IR, Lock}
  alias AshGrpc.Proto.Lock.ConflictError

  defp field(name, number \\ nil), do: %IR.Field{name: name, type: :string, number: number}

  defp message(fields, attrs \\ []) do
    struct!(%IR.Message{name: "User", full_name: "app.v1.User", fields: fields}, attrs)
  end

  defp file(messages, enums \\ []),
    do: %IR.File{path: "app/v1/app.proto", messages: messages, enums: enums}

  defp numbers(%IR.Message{fields: fields}), do: Enum.map(fields, &{&1.name, &1.number})
  defp numbers(%IR.Enum{values: values}), do: Enum.map(values, &{&1.name, &1.number})

  defp assign_message(message, lock \\ %Lock{}) do
    {%IR.File{messages: [message]}, lock} = Lock.assign(file([message]), lock)
    {message, lock}
  end

  describe "assign/2 for messages" do
    test "keeps explicit numbers and fills the rest in order" do
      {message, lock} = assign_message(message([field("id", 2), field("email"), field("name")]))

      assert numbers(message) == [{"id", 2}, {"email", 1}, {"name", 3}]
      assert lock.messages["app.v1.User"].fields == %{"id" => 2, "email" => 1, "name" => 3}
    end

    test "numbers from the lock are reused" do
      lock = %Lock{
        messages: %{
          "app.v1.User" => %{
            fields: %{"email" => 7, "id" => 1},
            reserved_numbers: [],
            reserved_names: []
          }
        }
      }

      {message, _lock} =
        assign_message(message([field("new"), field("id"), field("email")]), lock)

      assert numbers(message) == [{"new", 2}, {"id", 1}, {"email", 7}]
    end

    test "is stable: assigning twice yields the same result" do
      message = message([field("a"), field("b", 5), field("c")])
      {first, lock} = assign_message(message)
      {second, lock2} = assign_message(message, lock)
      assert numbers(first) == numbers(second)
      assert lock == lock2
    end

    test "removed fields are reserved in the lock and in the IR" do
      {_, lock} = assign_message(message([field("id"), field("email"), field("name")]))

      {message, lock} =
        assign_message(message([field("id"), field("name"), field("phone")]), lock)

      assert numbers(message) == [{"id", 1}, {"name", 3}, {"phone", 4}]
      assert message.reserved_numbers == [2]
      assert message.reserved_names == ["email"]
      assert lock.messages["app.v1.User"].reserved_numbers == [2]
      assert lock.messages["app.v1.User"].reserved_names == ["email"]

      # a later run without the DSL reservation still honours the lock
      {message, _} =
        assign_message(message([field("id"), field("name"), field("x"), field("y")]), lock)

      assert numbers(message) == [{"id", 1}, {"name", 3}, {"x", 5}, {"y", 6}]
      assert message.reserved_names == ["email", "phone"]
      assert message.reserved_numbers == [2, 4]
    end

    test "never reuses reserved numbers and skips 19000..19999" do
      message =
        message([field("a"), field("b"), field("c")],
          reserved_numbers: [1, {3, 18_999}],
          reserved_names: ["z"]
        )

      {message, lock} = assign_message(message)
      assert numbers(message) == [{"a", 2}, {"b", 20_000}, {"c", 20_001}]
      assert lock.messages["app.v1.User"].reserved_numbers == [1, {3, 18_999}]
      assert lock.messages["app.v1.User"].reserved_names == ["z"]
    end

    test "max ranges are honoured" do
      {message, _} =
        assign_message(message([field("a"), field("b")], reserved_numbers: [{3, :max}]))

      assert numbers(message) == [{"a", 1}, {"b", 2}]

      assert_raise ConflictError, ~r/no free number/, fn ->
        assign_message(message([field("a", 1), field("b")], reserved_numbers: [{2, :max}]))
      end
    end

    test "a moved field reserves its old number only" do
      {_, lock} = assign_message(message([field("id"), field("email")]))
      {message, lock} = assign_message(message([field("id"), field("email", 10)]), lock)

      assert numbers(message) == [{"id", 1}, {"email", 10}]
      assert message.reserved_numbers == [2]
      assert message.reserved_names == []
      assert lock.messages["app.v1.User"].fields == %{"id" => 1, "email" => 10}
    end

    test "nested messages and nested enums are assigned" do
      nested = %IR.Message{name: "Inner", full_name: "app.v1.User.Inner", fields: [field("x")]}

      enum = %IR.Enum{
        name: "Kind",
        full_name: "app.v1.User.Kind",
        values: [%IR.EnumValue{name: "KIND_UNSPECIFIED"}, %IR.EnumValue{name: "KIND_A"}]
      }

      {message, lock} =
        assign_message(message([field("id")], nested_messages: [nested], nested_enums: [enum]))

      assert [%{fields: [%{number: 1}]}] = message.nested_messages
      assert [%{values: [%{number: 0}, %{number: 1}]}] = message.nested_enums
      assert lock.messages["app.v1.User.Inner"].fields == %{"x" => 1}
      assert lock.enums["app.v1.User.Kind"].values == %{"KIND_UNSPECIFIED" => 0, "KIND_A" => 1}
    end

    test "lock entries of other messages are kept" do
      other = %{fields: %{"a" => 1}, reserved_numbers: [], reserved_names: []}
      {_, lock} = assign_message(message([field("id")]), %Lock{messages: %{"other.Msg" => other}})
      assert lock.messages["other.Msg"] == other
    end
  end

  describe "assign/2 conflicts" do
    setup do
      {_, lock} = assign_message(message([field("id"), field("email")]))
      %{lock: lock}
    end

    test "explicit number locked for a removed field", %{lock: lock} do
      error =
        assert_raise ConflictError, fn ->
          assign_message(message([field("id"), field("phone", 2)]), lock)
        end

      assert Exception.message(error) =~
               ~s(field app.v1.User.phone: number 2 is locked for "email")
    end

    test "explicit number locked for another existing field", %{lock: lock} do
      assert_raise ConflictError, ~r/locked for "email"/, fn ->
        assign_message(message([field("id"), field("email"), field("phone", 2)]), lock)
      end
    end

    test "explicit reserved, implementation-reserved and out-of-range numbers" do
      error =
        assert_raise ConflictError, fn ->
          assign_message(
            message([field("a", 3), field("b", 19_500), field("c", 0), field("d", 536_870_912)],
              reserved_numbers: [3]
            )
          )
        end

      assert length(error.errors) == 4
      assert Exception.message(error) =~ "app.v1.User.a: number 3 is reserved"
      assert Exception.message(error) =~ "19000..19999"
      assert Exception.message(error) =~ "out of range"
    end

    test "duplicate numbers and names, reserved names" do
      error =
        assert_raise ConflictError, fn ->
          assign_message(
            message([field("a", 1), field("b", 1), field("a"), field("old")],
              reserved_names: ["old"]
            )
          )
        end

      assert Exception.message(error) =~ ~s(number 1 is used by "a", "b")
      assert Exception.message(error) =~ "app.v1.User.a: duplicate name"
      assert Exception.message(error) =~ "app.v1.User.old: name is reserved"
    end

    test "locked number that became reserved", %{lock: lock} do
      assert_raise ConflictError, ~r/locked number 2 is reserved/, fn ->
        assign_message(message([field("id"), field("email")], reserved_numbers: [2]), lock)
      end
    end
  end

  describe "assign/2 for enums" do
    defp enum(values, attrs \\ []) do
      struct!(%IR.Enum{name: "Role", full_name: "app.v1.Role", values: values}, attrs)
    end

    defp value(name, number \\ nil), do: %IR.EnumValue{name: name, number: number}

    defp assign_enum(enum, lock \\ %Lock{}) do
      {%IR.File{enums: [enum]}, lock} = Lock.assign(file([], [enum]), lock)
      {enum, lock}
    end

    test "UNSPECIFIED gets 0, the rest counts from 1" do
      {enum, lock} =
        assign_enum(enum([value("ROLE_UNSPECIFIED"), value("ROLE_ADMIN"), value("ROLE_USER")]))

      assert numbers(enum) == [{"ROLE_UNSPECIFIED", 0}, {"ROLE_ADMIN", 1}, {"ROLE_USER", 2}]
      assert lock.enums["app.v1.Role"].values["ROLE_USER"] == 2
    end

    test "removed values are reserved, numbers are never reused" do
      {_, lock} =
        assign_enum(enum([value("ROLE_UNSPECIFIED"), value("ROLE_ADMIN"), value("ROLE_USER")]))

      {enum, lock} =
        assign_enum(
          enum([value("ROLE_UNSPECIFIED"), value("ROLE_USER"), value("ROLE_OWNER")]),
          lock
        )

      assert numbers(enum) == [{"ROLE_UNSPECIFIED", 0}, {"ROLE_USER", 2}, {"ROLE_OWNER", 3}]
      assert enum.reserved_numbers == [1]
      assert enum.reserved_names == ["ROLE_ADMIN"]
      assert lock.enums["app.v1.Role"].reserved_names == ["ROLE_ADMIN"]

      assert_raise ConflictError, ~r/number 1 is reserved/, fn ->
        assign_enum(enum([value("ROLE_UNSPECIFIED"), value("ROLE_GUEST", 1)]), lock)
      end
    end

    test "aliases are allowed with allow_alias?" do
      values = [value("A_UNSPECIFIED", 0), value("A_ONE", 1), value("A_UNO", 1)]
      {enum, lock} = assign_enum(enum(values, allow_alias?: true))
      assert numbers(enum) == [{"A_UNSPECIFIED", 0}, {"A_ONE", 1}, {"A_UNO", 1}]

      # stable with the lock, and removing one alias keeps the number in use
      {enum2, _} = assign_enum(enum(values, allow_alias?: true), lock)
      assert numbers(enum2) == numbers(enum)

      {enum3, _} =
        assign_enum(
          enum([value("A_UNSPECIFIED", 0), value("A_ONE", 1)], allow_alias?: true),
          lock
        )

      assert enum3.reserved_numbers == []
      assert enum3.reserved_names == ["A_UNO"]

      assert_raise ConflictError, ~r/number 1 is used by/, fn -> assign_enum(enum(values)) end
    end
  end

  describe "load/1, write!/2" do
    @tag :tmp_dir
    test "roundtrip with deterministic output", %{tmp_dir: dir} do
      path = Path.join([dir, "priv", "grpc", "ash_grpc.lock.json"])
      assert {:ok, %Lock{messages: m, enums: e}} = Lock.load(path)
      assert m == %{} and e == %{}

      message =
        message([field("id"), field("email"), field("name")],
          reserved_numbers: [{100, :max}, 50, {10, 12}, 11]
        )

      enum = %IR.Enum{
        name: "Role",
        full_name: "app.v1.Role",
        values: [%IR.EnumValue{name: "ROLE_UNSPECIFIED"}]
      }

      {_, lock} = Lock.assign(file([message], [enum]), %Lock{})

      assert :ok = Lock.write!(lock, path)
      assert {:ok, ^lock} = Lock.load(path)

      assert File.read!(path) == """
             {
               "version": 1,
               "messages": {
                 "app.v1.User": {
                   "fields": {
                     "id": 1,
                     "email": 2,
                     "name": 3
                   },
                   "reserved_numbers": [
                     [
                       10,
                       12
                     ],
                     50,
                     [
                       100,
                       "max"
                     ]
                   ],
                   "reserved_names": []
                 }
               },
               "enums": {
                 "app.v1.Role": {
                   "values": {
                     "ROLE_UNSPECIFIED": 0
                   },
                   "reserved_numbers": [],
                   "reserved_names": []
                 }
               }
             }
             """

      # writing again gives byte-identical output
      Lock.write!(lock, path)
      assert File.read!(path) == Lock.encode(lock)
    end

    @tag :tmp_dir
    test "invalid files", %{tmp_dir: dir} do
      path = Path.join(dir, "lock.json")

      File.write!(path, "{nope")
      assert {:error, {:invalid_json, _}} = Lock.load(path)

      File.write!(path, ~s({"version": 2}))
      assert {:error, {:unsupported_version, 2}} = Lock.load(path)

      File.write!(path, ~s({"version": 1, "messages": {"a.B": {"fields": {"x": "1"}}}}))
      assert {:error, {:invalid_entry, "a.B"}} = Lock.load(path)

      File.write!(path, ~s({"version": 1}))
      assert {:ok, %Lock{}} = Lock.load(path)
    end
  end
end
