defmodule AshGrpc.Proto.RenderTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.{IR, Render}
  alias AshGrpc.Test.ProtoFixtures

  defp render(file, opts \\ []), do: file |> Render.render(opts) |> IO.iodata_to_binary()

  defp file(attrs) do
    struct!(%IR.File{path: "t/v1/t.proto", package: "t.v1"}, attrs)
  end

  defp message(name, fields, attrs \\ []) do
    struct!(%IR.Message{name: name, full_name: "t.v1." <> name, fields: fields}, attrs)
  end

  describe "file level" do
    test "header, doc, syntax, package, sorted imports and options" do
      output =
        render(
          file(
            doc: "File doc.",
            imports: ["z.proto", "a.proto", "z.proto"],
            public_imports: ["m.proto"],
            options: [
              %IR.Option{name: "go_package", value: "x/y;y"},
              %IR.Option{name: "optimize_for", value: :SPEED},
              %IR.Option{name: "cc_enable_arenas", value: true}
            ]
          ),
          header: "Generated.\nDo not edit."
        )

      assert output == """
             // Generated.
             // Do not edit.

             // File doc.
             syntax = "proto3";

             package t.v1;

             import "a.proto";
             import public "m.proto";
             import "z.proto";

             option go_package = "x/y;y";
             option optimize_for = SPEED;
             option cc_enable_arenas = true;
             """
    end

    test "file without package" do
      assert render(%IR.File{path: "a.proto", messages: [%IR.Message{name: "A", full_name: "A"}]}) ==
               """
               syntax = "proto3";

               message A {}
               """
    end

    test "is deterministic" do
      file = ProtoFixtures.shop_file()
      assert render(file) == render(file)
    end

    test "editions are rendered best-effort" do
      output =
        render(
          file(
            syntax: {:edition, "2023"},
            messages: [
              message("A", [%IR.Field{name: "a", number: 1, type: :string, label: :optional}],
                reserved_names: ["old"]
              )
            ]
          )
        )

      assert output =~ ~s(edition = "2023";)
      assert output =~ "  string a = 1;"
      assert output =~ "  reserved old;"
    end
  end

  describe "messages" do
    test "labels, maps, oneofs, docs and nested types" do
      output = render(ProtoFixtures.shop_file())

      assert output =~ """
             // A shop user.
             //
             // Second paragraph.
             message User {
               option (acme.toolkit.v1.resource) = {
                 plural: "users"
                 type: "shop/User"
               };

               reserved 13, 15 to 17, 1000 to max;
               reserved "legacy", "old_name";

               // Primary key.
               string id = 1;
               optional string email = 2;
               Role role = 3;
               repeated string tags = 4;
               map<string, string> attributes = 5;
               map<int64, Role> role_by_org = 6;
               google.protobuf.Timestamp created_at = 7;
               Address address = 8;
               // How to reach the user.
               oneof contact {
                 string phone = 9;
                 string handle = 10;
               }
               double score = 11 [deprecated = true];
               int64 legacy_id = 12 [
                 json_name = "legacyID",
                 (acme.toolkit.v1.sensitive) = true
               ];
             """

      assert output =~ """
               message Address {
                 string street = 1;
                 optional string zip_code = 2;
                 Status status = 3;
               }

               enum Status {
                 STATUS_UNSPECIFIED = 0;
                 // Can sign in.
                 STATUS_ACTIVE = 1;
                 STATUS_BANNED = 2 [deprecated = true];
               }
             }
             """
    end

    test "oneof members are grouped where the first member appears" do
      output =
        render(
          file(
            messages: [
              message(
                "A",
                [
                  %IR.Field{name: "x", number: 1, type: :string, oneof: "choice"},
                  %IR.Field{name: "y", number: 2, type: :string},
                  %IR.Field{name: "z", number: 3, type: :int32, oneof: "choice"}
                ],
                oneofs: [
                  %IR.Oneof{
                    name: "choice",
                    options: [%IR.Option{name: "(my.opt)", value: 1}]
                  }
                ]
              )
            ]
          )
        )

      assert output =~ """
             message A {
               oneof choice {
                 option (my.opt) = 1;
                 string x = 1;
                 int32 z = 3;
               }
               string y = 2;
             }
             """
    end

    test "json_name equal to the protoc default is omitted" do
      output =
        render(
          file(
            messages: [
              message("A", [
                %IR.Field{name: "foo_bar", number: 1, type: :string, json_name: "fooBar"},
                %IR.Field{name: "baz", number: 2, type: :string, json_name: "BAZ"}
              ])
            ]
          )
        )

      assert output =~ "  string foo_bar = 1;\n"
      assert output =~ ~s(  string baz = 2 [json_name = "BAZ"];\n)
    end

    test "proto2 labels and defaults" do
      output = render(ProtoFixtures.legacy_file())

      assert output =~ """
             message Item {
               required int32 id = 1;
               optional string name = 2 [default = "unnamed"];
               optional double price = 3 [default = 1.5];
               optional Kind kind = 4 [default = KIND_B];
               repeated int32 flags = 5;
               optional bool active = 6 [default = true];
             }
             """
    end

    test "required is rejected in proto3" do
      file =
        file(
          messages: [
            message("A", [%IR.Field{name: "a", number: 1, type: :string, label: :required}])
          ]
        )

      assert_raise ArgumentError, ~r/required/, fn -> render(file) end
    end

    test "fields without numbers are rejected" do
      file = file(messages: [message("A", [%IR.Field{name: "a", type: :string}])])
      assert_raise ArgumentError, ~r/Lock.assign/, fn -> render(file) end
    end

    test "invalid identifiers are rejected" do
      bad = file(messages: [message("A;\nmessage B", [])])
      assert_raise ArgumentError, ~r/invalid message name/, fn -> render(bad) end

      bad = file(messages: [message("A", [%IR.Field{name: "a b", number: 1, type: :string}])])
      assert_raise ArgumentError, ~r/invalid field name/, fn -> render(bad) end

      bad =
        file(
          messages: [
            message("A", [%IR.Field{name: "a", number: 1, type: {:message, "x;y"}}])
          ]
        )

      assert_raise ArgumentError, ~r/invalid type name/, fn -> render(bad) end

      bad = file(options: [%IR.Option{name: "x = 1; option y", value: 1}])
      assert_raise ArgumentError, ~r/invalid option name/, fn -> render(bad) end
    end

    test "invalid map keys are rejected" do
      bad =
        file(
          messages: [
            message("A", [%IR.Field{name: "a", number: 1, type: {:map, :double, :string}}])
          ]
        )

      assert_raise ArgumentError, ~r/map key/, fn -> render(bad) end
    end
  end

  describe "type references" do
    test "foreign names are qualified, shadowed ones get a leading dot" do
      file = %IR.File{
        path: "acme/google/v1/x.proto",
        package: "acme.google.v1",
        messages: [
          %IR.Message{
            name: "A",
            full_name: "acme.google.v1.A",
            fields: [
              %IR.Field{name: "ts", number: 1, type: {:message, "google.protobuf.Timestamp"}},
              %IR.Field{name: "other", number: 2, type: {:message, "other.v1.Thing"}}
            ]
          }
        ]
      }

      output = render(file)
      assert output =~ "  .google.protobuf.Timestamp ts = 1;"
      assert output =~ "  other.v1.Thing other = 2;"
    end

    test "nested types shadowing a top-level name" do
      inner = %IR.Message{name: "B", full_name: "t.v1.A.B"}

      file =
        file(
          messages: [
            message("A", [%IR.Field{name: "top", number: 1, type: {:message, "t.v1.B"}}],
              nested_messages: [inner]
            ),
            message("B", [
              %IR.Field{name: "nested", number: 1, type: {:message, "t.v1.A.B"}}
            ])
          ]
        )

      output = render(file)
      assert output =~ "  .t.v1.B top = 1;"
      assert output =~ "  A.B nested = 1;"
    end

    test "types of the same package from another file stay short" do
      file =
        file(
          messages: [message("A", [%IR.Field{name: "o", number: 1, type: {:enum, "t.v1.Other"}}])]
        )

      assert render(file) =~ "  Other o = 1;"
    end
  end

  describe "enums and services" do
    test "enum aliases, reserved and options" do
      output = render(ProtoFixtures.shop_file())

      assert output =~ """
             // Access level.
             enum Role {
               option allow_alias = true;

               reserved 5, 7 to 9;
               reserved "ROLE_OLD";

               ROLE_UNSPECIFIED = 0;
               ROLE_ADMIN = 1;
               ROLE_USER = 2;
               ROLE_SUPERUSER = 1;
             }
             """
    end

    test "streaming kinds, idempotency and deprecation" do
      output = render(ProtoFixtures.shop_file())

      assert output =~ """
             // Manages users.
             service UserService {
               option deprecated = false;

               // Fetches a user.
               rpc GetUser(GetUserRequest) returns (User) {
                 option idempotency_level = NO_SIDE_EFFECTS;
               }

               rpc ListUsers(ListUsersRequest) returns (stream User);

               rpc ImportUsers(stream User) returns (google.protobuf.Empty);

               rpc SyncUsers(stream User) returns (stream User) {
                 option deprecated = true;
               }
             }
             """
    end
  end

  describe "constants" do
    test "strings are escaped" do
      assert IO.iodata_to_binary(Render.constant("a\"b\\c\nd\u0001é")) ==
               ~S("a\"b\\c\nd\001é")
    end

    test "aggregates with nested maps and lists" do
      value = %{"b" => [1, 2], "[ext.field]" => 1.5, a: %{x: :ENUM_X, y: "s"}}

      assert IO.iodata_to_binary(Render.constant(value)) == """
             {
               [ext.field]: 1.5
               a: {
                 x: ENUM_X
                 y: "s"
               }
               b: [1, 2]
             }\
             """
    end

    test "unsupported values raise" do
      assert_raise ArgumentError, fn -> Render.constant(nil) end
      assert_raise ArgumentError, fn -> Render.constant({:tuple}) end
      assert_raise ArgumentError, fn -> Render.constant(:"not an ident") end
    end
  end

  test "default_json_name/1 follows protoc" do
    assert Render.default_json_name("foo_bar_baz") == "fooBarBaz"
    assert Render.default_json_name("foo") == "foo"
    assert Render.default_json_name("foo_1") == "foo1"
    assert Render.default_json_name("_foo") == "Foo"
  end
end
