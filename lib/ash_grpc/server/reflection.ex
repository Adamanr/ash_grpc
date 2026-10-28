defmodule AshGrpc.Server.Reflection do
  @moduledoc """
  gRPC server reflection (`grpc.reflection.v1` / `v1alpha`) for `AshGrpc.Endpoint`s with
  `reflection: true`, built on the optional `grpc_reflection` dependency.

  The endpoint defines one `GrpcReflection.Server` per protocol version
  (`<Endpoint>.Reflection.V1`, `<Endpoint>.Reflection.V1alpha`) listing its services; the
  descriptors served are the `descriptor/0` functions that `AshGrpc.Proto.Compiler` emits for
  every message, enum and service. `AshGrpc.Server` starts the `grpc_reflection` processes
  (once per node) through `child_spec/1`.

  Tools such as `grpcurl`, Postman and `grpcui` can then list and call the services without
  `.proto` files.
  """

  # grpc_reflection is optional; this module is only used when it is installed
  @compile {:no_warn_undefined, GrpcReflection.Supervisor}

  @doc "Child spec starting the `grpc_reflection` supervisor unless it is already running."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :supervisor}
  end

  @doc false
  @spec start_link() :: Supervisor.on_start() | :ignore
  def start_link do
    if Process.whereis(GrpcReflection.Supervisor) do
      :ignore
    else
      case GrpcReflection.Supervisor.start_link([]) do
        {:error, {:already_started, _pid}} -> :ignore
        other -> other
      end
    end
  end
end
