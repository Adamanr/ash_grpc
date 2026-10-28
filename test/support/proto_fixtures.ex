defmodule AshGrpc.Test.ProtoFixtures do
  @moduledoc """
  Hand-written IR used by the proto toolkit tests (render, compiler, lock, diff).

  `shop_file/1` exercises most of the IR: nested types, oneofs, maps, proto3
  `optional`, enums with aliases, reserved ranges, options (incl. custom ones
  defined in `test/fixtures/protos/acme/toolkit/v1/options.proto`), docs and
  every streaming kind.
  """

  alias AshGrpc.Proto.IR

  @doc "Directory with hand-written `.proto` files used next to rendered ones."
  def protos_dir, do: Path.expand("../fixtures/protos", __DIR__)

  @doc "A rich proto3 file. `prefix` is the Elixir module prefix."
  def shop_file(prefix \\ AshGrpc.Test.Shop.V1) do
    pkg = "acme.shop.v1"
    mod = fn name -> Module.concat([prefix | String.split(name, ".")]) end

    status = %IR.Enum{
      name: "Status",
      full_name: "#{pkg}.User.Status",
      module: mod.("User.Status"),
      values: [
        %IR.EnumValue{name: "STATUS_UNSPECIFIED", number: 0},
        %IR.EnumValue{name: "STATUS_ACTIVE", number: 1, doc: "Can sign in."},
        %IR.EnumValue{name: "STATUS_BANNED", number: 2, deprecated?: true}
      ]
    }

    address = %IR.Message{
      name: "Address",
      full_name: "#{pkg}.User.Address",
      module: mod.("User.Address"),
      fields: [
        %IR.Field{name: "street", number: 1, type: :string},
        %IR.Field{name: "zip_code", number: 2, type: :string, label: :optional},
        %IR.Field{name: "status", number: 3, type: {:enum, "#{pkg}.User.Status"}}
      ]
    }

    user = %IR.Message{
      name: "User",
      full_name: "#{pkg}.User",
      module: mod.("User"),
      doc: "A shop user.\n\nSecond paragraph.",
      options: [
        %IR.Option{
          name: "(acme.toolkit.v1.resource)",
          value: %{type: "shop/User", plural: "users"}
        }
      ],
      reserved_numbers: [13, {15, 17}, {1000, :max}],
      reserved_names: ["old_name", "legacy"],
      oneofs: [%IR.Oneof{name: "contact", doc: "How to reach the user."}],
      nested_messages: [address],
      nested_enums: [status],
      fields: [
        %IR.Field{name: "id", number: 1, type: :string, doc: "Primary key."},
        %IR.Field{name: "email", number: 2, type: :string, label: :optional},
        %IR.Field{name: "role", number: 3, type: {:enum, "#{pkg}.Role"}},
        %IR.Field{name: "tags", number: 4, type: :string, label: :repeated},
        %IR.Field{name: "attributes", number: 5, type: {:map, :string, :string}},
        %IR.Field{name: "role_by_org", number: 6, type: {:map, :int64, {:enum, "#{pkg}.Role"}}},
        %IR.Field{
          name: "created_at",
          number: 7,
          type: {:message, "google.protobuf.Timestamp"}
        },
        %IR.Field{name: "address", number: 8, type: {:message, "#{pkg}.User.Address"}},
        %IR.Field{name: "phone", number: 9, type: :string, oneof: "contact"},
        %IR.Field{name: "handle", number: 10, type: :string, oneof: "contact"},
        %IR.Field{name: "score", number: 11, type: :double, deprecated?: true},
        %IR.Field{
          name: "legacy_id",
          number: 12,
          type: :int64,
          json_name: "legacyID",
          options: [%IR.Option{name: "(acme.toolkit.v1.sensitive)", value: true}]
        },
        %IR.Field{name: "scores", number: 14, type: :sint32, label: :repeated},
        %IR.Field{
          name: "addresses",
          number: 18,
          type: {:map, :string, {:message, "#{pkg}.User.Address"}}
        },
        %IR.Field{
          name: "status",
          number: 19,
          type: {:enum, "#{pkg}.User.Status"},
          label: :optional
        },
        %IR.Field{name: "avatar", number: 20, type: :bytes},
        %IR.Field{name: "counter", number: 21, type: :fixed64}
      ]
    }

    get_request = %IR.Message{
      name: "GetUserRequest",
      full_name: "#{pkg}.GetUserRequest",
      module: mod.("GetUserRequest"),
      fields: [%IR.Field{name: "id", number: 1, type: :string}]
    }

    list_request = %IR.Message{
      name: "ListUsersRequest",
      full_name: "#{pkg}.ListUsersRequest",
      module: mod.("ListUsersRequest"),
      fields: [
        %IR.Field{name: "page_size", number: 1, type: :int32},
        %IR.Field{name: "page_token", number: 2, type: :string},
        %IR.Field{name: "roles", number: 3, type: {:enum, "#{pkg}.Role"}, label: :repeated}
      ]
    }

    role = %IR.Enum{
      name: "Role",
      full_name: "#{pkg}.Role",
      module: mod.("Role"),
      doc: "Access level.",
      allow_alias?: true,
      reserved_numbers: [5, {7, 9}],
      reserved_names: ["ROLE_OLD"],
      values: [
        %IR.EnumValue{name: "ROLE_UNSPECIFIED", number: 0},
        %IR.EnumValue{name: "ROLE_ADMIN", number: 1},
        %IR.EnumValue{name: "ROLE_USER", number: 2},
        %IR.EnumValue{name: "ROLE_SUPERUSER", number: 1}
      ]
    }

    service = %IR.Service{
      name: "UserService",
      full_name: "#{pkg}.UserService",
      module: mod.("UserService.Service"),
      doc: "Manages users.",
      options: [%IR.Option{name: "deprecated", value: false}],
      rpcs: [
        %IR.Rpc{
          name: "GetUser",
          input: "#{pkg}.GetUserRequest",
          output: "#{pkg}.User",
          idempotency_level: :no_side_effects,
          doc: "Fetches a user."
        },
        %IR.Rpc{
          name: "ListUsers",
          input: "#{pkg}.ListUsersRequest",
          output: "#{pkg}.User",
          server_streaming?: true
        },
        %IR.Rpc{
          name: "ImportUsers",
          input: "#{pkg}.User",
          output: "google.protobuf.Empty",
          client_streaming?: true
        },
        %IR.Rpc{
          name: "SyncUsers",
          input: "#{pkg}.User",
          output: "#{pkg}.User",
          client_streaming?: true,
          server_streaming?: true,
          deprecated?: true
        }
      ]
    }

    %IR.File{
      path: "acme/shop/v1/shop.proto",
      package: pkg,
      doc: "Shop API.",
      imports: [
        "google/protobuf/timestamp.proto",
        "google/protobuf/empty.proto",
        "acme/toolkit/v1/options.proto"
      ],
      options: [
        %IR.Option{name: "go_package", value: "github.com/acme/shop/gen/v1;shopv1"},
        %IR.Option{name: "java_multiple_files", value: true},
        %IR.Option{name: "optimize_for", value: :SPEED}
      ],
      messages: [user, get_request, list_request],
      enums: [role],
      services: [service]
    }
  end

  @doc "A proto2 file with required fields and defaults."
  def legacy_file(prefix \\ AshGrpc.Test.Legacy) do
    pkg = "acme.legacy"

    %IR.File{
      path: "acme/legacy/legacy.proto",
      package: pkg,
      syntax: :proto2,
      messages: [
        %IR.Message{
          name: "Item",
          full_name: "#{pkg}.Item",
          module: Module.concat(prefix, Item),
          fields: [
            %IR.Field{name: "id", number: 1, type: :int32, label: :required},
            %IR.Field{name: "name", number: 2, type: :string, default: "unnamed"},
            %IR.Field{name: "price", number: 3, type: :double, label: :optional, default: 1.5},
            %IR.Field{name: "kind", number: 4, type: {:enum, "#{pkg}.Kind"}, default: :KIND_B},
            %IR.Field{name: "flags", number: 5, type: :int32, label: :repeated},
            %IR.Field{name: "active", number: 6, type: :bool, default: true}
          ]
        }
      ],
      enums: [
        %IR.Enum{
          name: "Kind",
          full_name: "#{pkg}.Kind",
          module: Module.concat(prefix, Kind),
          values: [
            %IR.EnumValue{name: "KIND_A", number: 1},
            %IR.EnumValue{name: "KIND_B", number: 2}
          ]
        }
      ]
    }
  end

  @doc "Wraps files in a schema."
  def schema(files), do: %IR.Schema{files: List.wrap(files)}
end
