defmodule AshGrpc.Test.Remote.Proto do
  @moduledoc false
  # Compiles the fake remote service from its fixture .proto (requires protoc).
  use AshGrpc.Protos,
    files: ["test/fixtures/protos/remote/ash_grpc/test/remote/v1/tickets.proto"],
    include: ["test/fixtures/protos/remote"],
    module_prefix: AshGrpc.Test.Remote.Proto
end
