defmodule AshGrpc.Test.Codegen.Widgets do
  @moduledoc """
  Versions of the same gRPC API (`ashgrpc.test.widgets.v1`) used to test codegen across schema
  changes. Each `Vn` domain renders the same `.proto` file; only the resource fields differ:

    * `V1` – `id`, `name`, `size`
    * `V2` – V1 + `color` (field added)
    * `V3` – V1 without `size` (field removed)
    * `V4` – `size` is a string (incompatible type change)
  """

  @doc false
  defmacro widget_api(version, attributes, fields) do
    version = Macro.expand(version, __CALLER__)
    domain = Module.concat([__MODULE__, version])
    resource = Module.concat([domain, Widget])

    quote do
      defmodule unquote(domain) do
        @moduledoc false
        use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

        grpc do
          package "ashgrpc.test.widgets.v1"
          module_prefix unquote(Module.concat([AshGrpc.Test.Proto.Widgets, version]))
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

        ets do
          private? true
        end

        attributes do
          uuid_primary_key :id, public?: true
          unquote(attributes)
          create_timestamp :inserted_at, public?: true
        end

        actions do
          defaults [:read, :destroy, create: :*]
        end

        grpc do
          message "Widget"
          fields unquote(fields)

          rpc :get_widget, :read, kind: :get
          rpc :list_widgets, :read
          rpc :create_widget, :create
          rpc :delete_widget, :destroy
        end
      end
    end
  end
end

defmodule AshGrpc.Test.Codegen.Widgets.Versions do
  @moduledoc false
  require AshGrpc.Test.Codegen.Widgets
  import AshGrpc.Test.Codegen.Widgets

  widget_api(
    V1,
    (
      attribute :name, :string, public?: true
      attribute :size, :integer, public?: true
    ),
    [:id, :name, :size, :inserted_at]
  )

  widget_api(
    V2,
    (
      attribute :name, :string, public?: true
      attribute :size, :integer, public?: true
      attribute :color, :string, public?: true
    ),
    [:id, :name, :size, :color, :inserted_at]
  )

  widget_api(
    V3,
    attribute(:name, :string, public?: true),
    [:id, :name, :inserted_at]
  )

  widget_api(
    V4,
    (
      attribute :name, :string, public?: true
      attribute :size, :string, public?: true
    ),
    [:id, :name, :size, :inserted_at]
  )
end

defmodule AshGrpc.Test.Codegen.Gadgets do
  @moduledoc false
  # A second, independent API: checks that generating one domain leaves the other alone.
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.test.gadgets.v1"
  end

  resources do
    resource AshGrpc.Test.Codegen.Gadget
  end
end

defmodule AshGrpc.Test.Codegen.Gadget do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Codegen.Gadgets,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  grpc do
    rpc :get_gadget, :read, kind: :get
  end
end
