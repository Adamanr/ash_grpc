defmodule AshGrpc.Test.E2E.Shelves do
  @moduledoc """
  Versions of one gRPC API (`ashgrpc.e2e.shelves.v1`) for the compatibility end-to-end test.
  Every `Vn` domain renders the same `.proto` file; only the `Shelf` fields differ:

    * `V1` – `id`, `name`, `size`
    * `V2` – V1 + `color` (field added)
    * `V3` – V2 without `size` and `color` (fields removed)

  Their endpoints are compiled by the test itself, against the lock that codegen wrote.
  """

  @doc false
  defmacro shelf_api(version, attributes, fields) do
    version = Macro.expand(version, __CALLER__)
    domain = Module.concat([__MODULE__, version])
    resource = Module.concat([domain, Shelf])

    quote do
      defmodule unquote(domain) do
        @moduledoc false
        use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

        grpc do
          package "ashgrpc.e2e.shelves.v1"
          module_prefix unquote(Module.concat([AshGrpc.Test.E2E.Shelves.Proto, version]))
        end

        resources do
          resource unquote(resource)
        end
      end

      defmodule unquote(resource) do
        @moduledoc false
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrpc.Resource]

        resource do
          # the list field would otherwise be the naive plural `shelfs`
          plural_name :shelves
        end

        attributes do
          uuid_primary_key :id, public?: true
          attribute :name, :string, allow_nil?: false, public?: true
          unquote(attributes)
          create_timestamp :inserted_at, public?: true
        end

        actions do
          defaults [:read, create: :*]
        end

        grpc do
          message "Shelf"
          fields unquote(fields)

          rpc :get_shelf, :read, kind: :get
          rpc :list_shelves, :read
          rpc :create_shelf, :create
        end
      end
    end
  end
end

defmodule AshGrpc.Test.E2E.Shelves.Versions do
  @moduledoc false
  require AshGrpc.Test.E2E.Shelves
  import AshGrpc.Test.E2E.Shelves

  shelf_api(V1, attribute(:size, :integer, public?: true), [:id, :name, :size, :inserted_at])

  shelf_api(
    V2,
    (
      attribute :size, :integer, public?: true
      attribute :color, :string, public?: true
    ),
    [:id, :name, :size, :color, :inserted_at]
  )

  shelf_api(V3, nil, [:id, :name, :inserted_at])
end
