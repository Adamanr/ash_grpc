defmodule AshGrpc.DataLayer.Verifiers.VerifyClient do
  @moduledoc """
  Verifies that the `client` of `grpc_remote` is a compiled `use AshGrpc.Client` module and
  that `message` is a protobuf module carrying a descriptor.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    client = Verifier.get_option(dsl_state, [:grpc_remote], :client)
    message = Verifier.get_option(dsl_state, [:grpc_remote], :message)

    cond do
      not client_module?(client) ->
        error(
          module,
          :client,
          "#{inspect(client)} is not a compiled `use AshGrpc.Client` module"
        )

      not message_module?(message) ->
        error(
          module,
          :message,
          "#{inspect(message)} is not a compiled protobuf message module with descriptor/0"
        )

      true ->
        :ok
    end
  end

  @doc false
  @spec client_module?(term()) :: boolean()
  def client_module?(client) do
    is_atom(client) and match?({:module, _}, Code.ensure_compiled(client)) and
      function_exported?(client, :__rpc_table__, 0)
  end

  defp message_module?(message) do
    is_atom(message) and match?({:module, _}, Code.ensure_compiled(message)) and
      function_exported?(message, :__message_props__, 0) and
      not message.__message_props__().enum? and function_exported?(message, :descriptor, 0)
  end

  defp error(module, option, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: module,
       path: [:grpc_remote, option],
       message: message
     )}
  end
end
