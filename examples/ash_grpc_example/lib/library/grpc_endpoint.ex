defmodule Library.GrpcEndpoint do
  @moduledoc "The gRPC endpoint of the library service."
  use AshGrpc.Endpoint,
    otp_app: :ash_grpc_example,
    domains: [Library],
    interceptors: [
      AshGrpc.Interceptors.Logger,
      {AshGrpc.Interceptors.Actor, from: Library.Auth}
    ],
    reflection: true,
    health: true
end
