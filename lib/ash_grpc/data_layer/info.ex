defmodule AshGrpc.DataLayer.Info do
  @moduledoc "Introspection of the `grpc_remote` section of `AshGrpc.DataLayer` resources."

  use Spark.InfoGenerator, extension: AshGrpc.DataLayer, sections: [:grpc_remote]

  alias AshGrpc.DataLayer.Operation

  @doc "Every operation (rpc) of the resource."
  @spec operations(Spark.Dsl.t() | Ash.Resource.t()) :: [Operation.t()]
  def operations(resource), do: grpc_remote(resource)

  @doc "The operations of the given kind."
  @spec operations(Spark.Dsl.t() | Ash.Resource.t(), Operation.kind()) :: [Operation.t()]
  def operations(resource, kind), do: resource |> operations() |> Enum.filter(&(&1.kind == kind))

  @doc "The operation of the given kind (the first one, for kinds that may only appear once)."
  @spec operation(Spark.Dsl.t() | Ash.Resource.t(), Operation.kind()) :: Operation.t() | nil
  def operation(resource, kind), do: resource |> operations(kind) |> List.first()

  @doc """
  The read operation for the read action `action` (a name or `nil`): one listing the action in
  `actions`, else the first one without `actions`.
  """
  @spec read_operation(Spark.Dsl.t() | Ash.Resource.t(), atom() | nil) :: Operation.t() | nil
  def read_operation(resource, action) do
    reads = operations(resource, :read)

    Enum.find(reads, &(action && &1.actions && action in &1.actions)) ||
      Enum.find(reads, &is_nil(&1.actions))
  end

  @doc "An option of the `grpc_remote` section, or `default` when not set."
  @spec option(Spark.Dsl.t() | Ash.Resource.t(), atom(), term()) :: term()
  def option(resource, name, default \\ nil),
    do: Spark.Dsl.Extension.get_opt(resource, [:grpc_remote], name, default)

  @doc "The proto field name of `attribute` (see the `fields` option)."
  @spec field_name(Spark.Dsl.t() | Ash.Resource.t(), atom()) :: String.t()
  def field_name(resource, attribute) do
    case Keyword.fetch(grpc_remote_fields!(resource), attribute) do
      {:ok, name} -> to_string(name)
      :error -> to_string(attribute)
    end
  end
end
