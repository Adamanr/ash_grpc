defmodule AshGrpc do
  @moduledoc """
  gRPC for the Ash Framework.

    * expose Ash actions as gRPC services (`AshGrpc.Resource`, `AshGrpc.Domain`, `AshGrpc.Endpoint`)
    * generate `.proto` files from the DSL and keep wire numbers stable (`mix ash_grpc.codegen`)
    * connect to any number of external gRPC services (`AshGrpc.Client`)
    * import foreign `.proto` files and use them from Ash (`mix ash_grpc.import`, `AshGrpc.DataLayer`)

  See `DESIGN.md` for the architecture.
  """
end
