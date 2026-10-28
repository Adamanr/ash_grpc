defmodule AshGrpc.Proto.LockTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.{IR, Lock}

  test "assign/2 keeps explicit numbers and fills the rest in order" do
    message = %IR.Message{
      name: "User",
      full_name: "app.v1.User",
      fields: [
        %IR.Field{name: "id", type: :string, number: 2},
        %IR.Field{name: "email", type: :string},
        %IR.Field{name: "name", type: :string}
      ]
    }

    {file, lock} = Lock.assign(%IR.File{path: "app/v1/app.proto", messages: [message]}, %Lock{})

    assert [%{fields: fields}] = file.messages
    assert Enum.map(fields, &{&1.name, &1.number}) == [{"id", 2}, {"email", 1}, {"name", 3}]
    assert lock.messages["app.v1.User"].fields == %{"id" => 2, "email" => 1, "name" => 3}
  end
end
