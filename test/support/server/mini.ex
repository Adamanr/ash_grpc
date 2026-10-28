defmodule AshGrpc.Test.Server.Mini do
  @moduledoc false
  # A tiny domain for endpoint compilation tests (compiled into throwaway endpoints).
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.test.mini.v1"
    module_prefix AshGrpc.Test.Server.Mini.Proto.V1
  end

  resources do
    resource AshGrpc.Test.Server.Mini.Thing
  end
end

defmodule AshGrpc.Test.Server.Mini.Thing do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Server.Mini,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  grpc do
    rpc :get_thing, :read, get_by: [:id]
  end
end
