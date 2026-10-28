defmodule AshGrpc.Resource do
  @field %Spark.Dsl.Entity{
    name: :field,
    target: AshGrpc.Resource.Field,
    args: [:name],
    identifier: :name,
    describe: """
    Fine-tunes a field of the resource message: number, proto name, representation, docs and options.
    The field must be part of the message (see `fields`).
    """,
    examples: [
      "field :id, number: 1",
      ~s(field :role, number: 3, doc: "Access level"),
      "field :inserted_at, representation: :string",
      ~s(field :admin?, proto_name: "is_admin")
    ],
    schema: AshGrpc.Resource.Field.schema()
  }

  @reserved %Spark.Dsl.Entity{
    name: :reserved,
    target: AshGrpc.Resource.Reserved,
    describe: "Field numbers and names of removed fields that must never be reused.",
    examples: [~s(reserved numbers: [4, 10..12], names: ["legacy_name"])],
    schema: AshGrpc.Resource.Reserved.schema()
  }

  @rpc %Spark.Dsl.Entity{
    name: :rpc,
    target: AshGrpc.Resource.Rpc,
    args: [:name, :action],
    identifier: :name,
    no_depend_modules: [:handler, :request_message, :response_message],
    describe: """
    Exposes an action as a gRPC method. See DESIGN.md §4.4 for the request/response shapes of each kind.
    """,
    examples: [
      "rpc :get_user, :read, get_by: [:id]",
      "rpc :list_users, :read, kind: :list, filter?: true",
      "rpc :watch_users, :read, kind: :server_stream",
      "rpc :update_user, :update, update_mask?: true",
      "rpc :sync, :sync, kind: :bidi_stream, handler: MyApp.Grpc.SyncHandler"
    ],
    schema: AshGrpc.Resource.Rpc.schema()
  }

  @grpc %Spark.Dsl.Section{
    name: :grpc,
    describe: "Exposes the resource as a protobuf message and its actions as gRPC methods.",
    examples: [
      """
      grpc do
        message "User"
        fields [:id, :email, :role, :display_name, :posts]

        field :id, number: 1
        field :role, doc: "Access level"
        reserved numbers: [4], names: ["legacy_name"]

        rpc :get_user, :read, get_by: [:id]
        rpc :list_users, :read
        rpc :create_user, :create
        rpc :update_user, :update, update_mask?: true
        rpc :delete_user, :destroy
      end
      """
    ],
    schema: [
      message: [
        type: :string,
        doc: "The message name (PascalCase). Defaults to the last segment of the module name."
      ],
      fields: [
        type: {:list, :atom},
        doc: """
        Attributes, calculations, aggregates and relationships that make up the message, in order.
        Defaults to the public attributes. Private fields may be listed explicitly.
        Relationships become nested messages (the destination must use `AshGrpc.Resource`).
        """
      ],
      doc: [type: :string, doc: "Message comment. Defaults to the resource description."],
      options: [
        type: {:list, {:tuple, [{:or, [:atom, :string]}, :any]}},
        default: [],
        doc: "Message options."
      ]
    ],
    entities: [@field, @reserved, @rpc]
  }

  @sections [@grpc]

  @moduledoc """
  Spark extension that exposes an Ash resource over gRPC.

  ```elixir
  use Ash.Resource, domain: MyApp.Accounts, extensions: [AshGrpc.Resource]
  ```

  The resource message, request/response messages and services are built by
  `AshGrpc.Schema.build/2` (the domain must use `AshGrpc.Domain`). Embedded resources may use
  this extension to tune their message (`message`, `fields`, `field`, `reserved`); they cannot
  declare rpcs.

  See the generated DSL documentation for all options.
  """

  use Spark.Dsl.Extension,
    sections: @sections,
    verifiers: [
      AshGrpc.Resource.Verifiers.VerifyFields,
      AshGrpc.Resource.Verifiers.VerifyRpcs
    ]
end
