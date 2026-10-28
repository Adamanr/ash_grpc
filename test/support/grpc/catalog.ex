defmodule AshGrpc.Test.Catalog do
  @moduledoc false
  # Defaults only: file, module prefix and service are derived from the package.
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.test.catalog.v1"
  end

  resources do
    resource AshGrpc.Test.Product
  end
end

defmodule AshGrpc.Test.Product do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Catalog,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
    attribute :price, :decimal, public?: true
    attribute :warehouse, AshGrpc.Test.Address, public?: true
    attribute :released_on, :date, public?: true
  end

  relationships do
    belongs_to :owner, AshGrpc.Test.User, public?: true
  end

  actions do
    defaults [:read]
  end

  grpc do
    fields [:id, :title, :price, :warehouse, :released_on, :owner]
    rpc :get_product, :read, kind: :get
    rpc :list_products, :read
  end
end
