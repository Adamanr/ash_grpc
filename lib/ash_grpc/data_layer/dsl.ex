defmodule AshGrpc.DataLayer.Dsl do
  @moduledoc false
  # The `grpc_remote` section of `AshGrpc.DataLayer`.

  alias AshGrpc.DataLayer.Operation

  @field_name {:or, [:atom, :string]}

  @rpc_arg [
    rpc: [
      type: {:or, [:atom, :string]},
      required: true,
      doc:
        "The rpc of the client: proto name (`:GetTicket`), snake_case name (`:get_ticket`) or `\"/pkg.Service/Method\"`."
    ]
  ]

  @response_opt [
    response: [
      type: {:or, [@field_name, {:list, @field_name}]},
      doc:
        "Field (or field path) of the response holding the record. Default: the response is the record message."
    ]
  ]

  @request_opt [
    request: [
      type: @field_name,
      doc:
        "Field of the request that holds the record message (AIP style `{ Ticket ticket = 1; }`). Default: the record's fields are request fields (flat)."
    ]
  ]

  @by_opt [
    by: [
      type: {:wrap_list, :atom},
      doc:
        "Attributes sent as request fields to identify the record (mapped with `fields`). Default: the primary key."
    ]
  ]

  @read %Spark.Dsl.Entity{
    name: :read,
    describe: "The list rpc used for reads.",
    target: Operation,
    args: [:rpc],
    auto_set_fields: [kind: :read],
    examples: ["read :list_tickets, filter: [:owner_id, :status]"],
    schema:
      @rpc_arg ++
        [
          actions: [
            type: {:wrap_list, :atom},
            doc: "Read actions using this rpc. Default: every read action without its own rpc."
          ],
          filter: [
            type: {:list, {:or, [:atom, {:tuple, [:atom, @field_name]}]}},
            default: [],
            doc:
              "Attributes whose equality filters are pushed down as request fields: `[:owner_id]` or `[owner_id: \"owner\"]`."
          ],
          paginate: [
            type: {:one_of, [:page_token, :none]},
            default: :page_token,
            doc: "`:page_token` (AIP-158 `page_size`/`page_token`/`next_page_token`) or `:none`."
          ],
          records: [
            type: @field_name,
            doc:
              "Repeated field of the response with the records. Default: the first repeated field of the record message type."
          ],
          page_size_field: [
            type: @field_name,
            default: :page_size,
            doc: "Request field for the page size."
          ],
          page_token_field: [
            type: @field_name,
            default: :page_token,
            doc: "Request field for the page token."
          ],
          next_page_token_field: [
            type: @field_name,
            default: :next_page_token,
            doc: "Response field with the next page token."
          ]
        ]
  }

  @get %Spark.Dsl.Entity{
    name: :get,
    describe:
      "The rpc fetching one record, used for reads filtering on (at least) every `by` attribute with equality.",
    target: Operation,
    args: [:rpc],
    auto_set_fields: [kind: :get],
    examples: ["get :get_ticket, by: :id"],
    schema: @rpc_arg ++ @by_opt ++ @response_opt
  }

  @create %Spark.Dsl.Entity{
    name: :create,
    describe: "The rpc creating records.",
    target: Operation,
    args: [:rpc],
    auto_set_fields: [kind: :create],
    examples: ["create :create_ticket, request: :ticket"],
    schema: @rpc_arg ++ @request_opt ++ @response_opt
  }

  @update %Spark.Dsl.Entity{
    name: :update,
    describe: "The rpc updating records.",
    target: Operation,
    args: [:rpc],
    auto_set_fields: [kind: :update],
    examples: ["update :update_ticket, request: :ticket, update_mask: :update_mask"],
    schema:
      @rpc_arg ++
        @request_opt ++
        @response_opt ++
        [
          update_mask: [
            type: @field_name,
            doc:
              "`google.protobuf.FieldMask` request field, set to the proto names of the changed attributes (AIP-134)."
          ]
        ]
  }

  @destroy %Spark.Dsl.Entity{
    name: :destroy,
    describe: "The rpc destroying records. Its response is ignored.",
    target: Operation,
    args: [:rpc],
    auto_set_fields: [kind: :destroy],
    examples: ["destroy :delete_ticket"],
    schema: @rpc_arg ++ @by_opt
  }

  @section %Spark.Dsl.Section{
    name: :grpc_remote,
    describe:
      "Backs the resource by an external gRPC service, called through an `AshGrpc.Client`.",
    examples: [
      """
      grpc_remote do
        client MyApp.Tickets
        message MyApp.Proto.Ticket
        read :list_tickets, filter: [:owner_id, :status]
        get :get_ticket, by: :id
        create :create_ticket, request: :ticket
        update :update_ticket, request: :ticket, update_mask: :update_mask
        destroy :delete_ticket
      end
      """
    ],
    entities: [@read, @get, @create, @update, @destroy],
    schema: [
      client: [
        type: :atom,
        required: true,
        doc: "The `use AshGrpc.Client` module (or dynamic client name) to call."
      ],
      message: [
        type: :atom,
        required: true,
        doc: "The protobuf module of the record message."
      ],
      fields: [
        type: :keyword_list,
        default: [],
        doc:
          "Attribute name => proto field name, for attributes whose name differs from the field (`[owner: \"owner_id\"]`). Other attributes map to the field of the same name, if any."
      ],
      strict_filters?: [
        type: :boolean,
        default: false,
        doc:
          "Raise instead of filtering in memory when a filter cannot be pushed down entirely to the rpc."
      ],
      page_size: [
        type: :pos_integer,
        default: 100,
        doc: "Page size requested when reading pages."
      ],
      max_pages: [
        type: :pos_integer,
        default: 100,
        doc:
          "Maximum number of pages fetched by one read (the read stops there and logs a warning)."
      ],
      deadline: [
        type: {:or, [:pos_integer, nil]},
        doc:
          "Deadline (ms) of each call. Default: the action timeout, else the client's deadline."
      ],
      metadata: [
        type: {:or, [{:fun, 1}, :mfa, :map, nil]},
        doc:
          "Extra call metadata: a map, or a function / `{m, f, a}` receiving `%{actor:, tenant:, resource:, action:, context:}` (MFA: as first argument) and returning a map. The actor and tenant are also passed to the client as call options `:actor`/`:tenant`, for the client's own `:metadata` function."
      ]
    ]
  }

  @doc false
  def section, do: @section
end
