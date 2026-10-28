defmodule AshGrpc.Server.Health.Proto do
  @moduledoc """
  The `grpc.health.v1` schema (`grpc/health/v1/health.proto`) as IR. Its modules
  (`AshGrpc.Server.Health.V1.*`) are compiled from this IR by `AshGrpc.Proto.Compiler`, like
  every other AshGrpc service.
  """

  alias AshGrpc.Proto.IR

  @package "grpc.health.v1"
  @prefix AshGrpc.Server.Health.V1

  @doc "The IR schema of `grpc.health.v1`."
  @spec schema() :: IR.Schema.t()
  def schema do
    request = %IR.Message{
      name: "HealthCheckRequest",
      full_name: full("HealthCheckRequest"),
      module: Module.concat(@prefix, HealthCheckRequest),
      fields: [%IR.Field{name: "service", number: 1, type: :string}]
    }

    status = %IR.Enum{
      name: "ServingStatus",
      full_name: full("HealthCheckResponse.ServingStatus"),
      module: Module.concat(@prefix, HealthCheckResponse.ServingStatus),
      values: [
        %IR.EnumValue{name: "UNKNOWN", number: 0},
        %IR.EnumValue{name: "SERVING", number: 1},
        %IR.EnumValue{name: "NOT_SERVING", number: 2},
        %IR.EnumValue{name: "SERVICE_UNKNOWN", number: 3}
      ]
    }

    response = %IR.Message{
      name: "HealthCheckResponse",
      full_name: full("HealthCheckResponse"),
      module: Module.concat(@prefix, HealthCheckResponse),
      nested_enums: [status],
      fields: [
        %IR.Field{name: "status", number: 1, type: {:enum, status.full_name}}
      ]
    }

    service = %IR.Service{
      name: "Health",
      full_name: full("Health"),
      module: service_module(),
      rpcs: [
        %IR.Rpc{name: "Check", input: request.full_name, output: response.full_name},
        %IR.Rpc{
          name: "Watch",
          input: request.full_name,
          output: response.full_name,
          server_streaming?: true
        }
      ]
    }

    %IR.Schema{
      files: [
        %IR.File{
          path: "grpc/health/v1/health.proto",
          package: @package,
          options: [
            %IR.Option{name: "java_package", value: "io.grpc.health.v1"},
            %IR.Option{name: "java_multiple_files", value: true},
            %IR.Option{name: "java_outer_classname", value: "HealthProto"}
          ],
          messages: [request, response],
          services: [service]
        }
      ]
    }
  end

  @doc "The `GRPC.Service` module of `grpc.health.v1.Health`."
  @spec service_module() :: module()
  def service_module, do: Module.concat(@prefix, Health.Service)

  defp full(name), do: @package <> "." <> name
end

defmodule AshGrpc.Server.StatusProto do
  @moduledoc """
  `google.rpc.Status` compiled by `AshGrpc.Proto.Compiler` as
  `AshGrpc.Server.Proto.Google.Rpc.Status`.

  Endpoints use it (instead of the `googleapis` module, which has no descriptor) for
  `google.rpc.Status` fields of their messages (the `errors` of client-streaming responses),
  so server reflection can describe them. Both modules have the same wire format.
  """

  alias AshGrpc.Proto.IR

  @doc "The IR schema of `google/rpc/status.proto`."
  @spec schema() :: IR.Schema.t()
  def schema do
    %IR.Schema{
      files: [
        %IR.File{
          path: "google/rpc/status.proto",
          package: "google.rpc",
          imports: ["google/protobuf/any.proto"],
          messages: [
            %IR.Message{
              name: "Status",
              full_name: "google.rpc.Status",
              module: module(),
              fields: [
                %IR.Field{name: "code", number: 1, type: :int32},
                %IR.Field{name: "message", number: 2, type: :string},
                %IR.Field{
                  name: "details",
                  number: 3,
                  type: {:message, "google.protobuf.Any"},
                  label: :repeated
                }
              ]
            }
          ]
        }
      ]
    }
  end

  @doc "The module of `google.rpc.Status` used by endpoints."
  @spec module() :: module()
  def module, do: AshGrpc.Server.Proto.Google.Rpc.Status

  @doc "`AshGrpc.Proto.Compiler` `:modules` option mapping `google.rpc.Status` to `module/0`."
  @spec modules() :: %{String.t() => module()}
  def modules, do: %{"google.rpc.Status" => module()}
end

defmodule AshGrpc.Server.Builder.Protos do
  @moduledoc false
  # Defines the modules of an IR schema known at compile time (persisted as .beam files).

  defmacro define(schema) do
    {schema, _} = Code.eval_quoted(schema, [], __CALLER__)
    {:__block__, [], schema |> AshGrpc.Proto.Compiler.quoted() |> Enum.map(&elem(&1, 1))}
  end
end
