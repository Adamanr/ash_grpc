# Fixtures that pass the DSL verifiers but fail `AshGrpc.Schema.build/2`.

defmodule AshGrpc.Test.Fixtures.SameA do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.test.same.v1"
    file "ashgrpc/test/same/v1/a.proto"
  end

  resources do
    resource AshGrpc.Test.Fixtures.SameA.Thing
  end
end

defmodule AshGrpc.Test.Fixtures.SameA.Thing do
  @moduledoc false
  use Ash.Resource, domain: AshGrpc.Test.Fixtures.SameA, extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
  end

  actions do
    defaults [:read]

    read :search do
      argument :page_size, :integer
    end

    action :echo, :string do
      run fn _, _ -> {:ok, ""} end
    end
  end

  grpc do
    rpc :list_things, :search
    rpc :echo, :echo, response_message: "EchoReply"
    rpc :get_thing, :read, kind: :get, response_message: "ThingReply"
  end
end

defmodule AshGrpc.Test.Fixtures.SameB do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.test.same.v1"
    file "ashgrpc/test/same/v1/b.proto"
  end

  resources do
    resource AshGrpc.Test.Fixtures.SameB.Thing
  end
end

defmodule AshGrpc.Test.Fixtures.SameB.Thing do
  @moduledoc false
  use Ash.Resource, domain: AshGrpc.Test.Fixtures.SameB, extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
  end

  actions do
    defaults [:read]
  end

  grpc do
    rpc :get_other_thing, :read, kind: :get
  end
end
