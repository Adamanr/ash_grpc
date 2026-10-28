defmodule AshGrpc.DataLayer.Verifiers.VerifyRpcs do
  @moduledoc """
  Verifies that every rpc of `grpc_remote` exists (unambiguously) on the services of the client
  and is unary, and that `get`, `create`, `update` and `destroy` appear at most once.
  """
  use Spark.Dsl.Verifier

  alias AshGrpc.DataLayer.Verifiers.VerifyClient
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    client = Verifier.get_option(dsl_state, [:grpc_remote], :client)
    operations = Verifier.get_entities(dsl_state, [:grpc_remote])

    with :ok <- verify_unique(module, operations) do
      if VerifyClient.client_module?(client) do
        first_error(operations, &verify_rpc(module, client, &1))
      else
        # reported by VerifyClient
        :ok
      end
    end
  end

  defp verify_unique(module, operations) do
    operations
    |> Enum.reject(&(&1.kind == :read))
    |> Enum.frequencies_by(& &1.kind)
    |> Enum.find(fn {_kind, count} -> count > 1 end)
    |> case do
      nil ->
        :ok

      {kind, _} ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:grpc_remote, kind],
           message: "`#{kind}` may only be declared once"
         )}
    end
  end

  defp verify_rpc(module, client, op) do
    case AshGrpc.Client.RpcTable.fetch(client.__rpc_table__(), op.rpc) do
      {:ok, %{grpc_type: :unary}} ->
        :ok

      {:ok, entry} ->
        error(
          module,
          op,
          "#{inspect(op.rpc)} is a #{entry.grpc_type} rpc; only unary rpcs are supported"
        )

      {:error, error} ->
        error(module, op, "#{inspect(client)}: #{Exception.message(error)}")
    end
  end

  defp error(module, op, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: module,
       path: [:grpc_remote, op.kind, op.rpc],
       message: message,
       location: Spark.Dsl.Entity.anno(op)
     )}
  end

  defp first_error(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
