defmodule AshGrpc.Types do
  @moduledoc """
  Types for the `grpc` structs used in AshGrpc's specs (grpc 1.0 does not define `t()` types
  for them).
  """

  # credo:disable-for-lines:13 Credo.Check.Warning.SpecWithStruct
  @typedoc "A gRPC status error (`GRPC.RPCError`)."
  @type rpc_error :: %GRPC.RPCError{}

  @typedoc "The stream of an incoming request (`GRPC.Server.Stream`)."
  @type server_stream :: %GRPC.Server.Stream{}

  @typedoc "A client channel (`GRPC.Channel`)."
  @type channel :: %GRPC.Channel{}

  @typedoc "TLS credentials (`GRPC.Credential`)."
  @type credential :: %GRPC.Credential{}
end
