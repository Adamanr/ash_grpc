defmodule AshGrpc.Schema.Types do
  @moduledoc false
  # Type mapping used by the schema builder and the verifiers.
  #
  # Resources (embedded resources, `:struct` with `instance_of: Resource`) are owned by the
  # schema builder: they are resolved here via `opts[:resolve_resource]` before falling back to
  # `AshGrpc.Type.Mapping.to_proto/3` (which receives the same option for nested occurrences).

  alias AshGrpc.Type.Mapping
  alias AshGrpc.Type.Mapping.Result

  @spec map(Ash.Type.t(), Keyword.t(), Keyword.t()) :: {:ok, Result.t()} | {:error, term()}
  def map(type, constraints, opts) do
    resource = !opts[:representation] && resource_type(type, constraints)

    case resource do
      {resource, repeated?} ->
        case opts[:resolve_resource].(resource) do
          nil ->
            {:error, {:unresolved_resource, resource}}

          full_name ->
            {:ok, %Result{type: {:message, full_name}, label: if(repeated?, do: :repeated)}}
        end

      _ ->
        Mapping.to_proto(type, constraints || [], opts)
    end
  end

  @doc false
  # `{resource, repeated?}` when the type is a resource (embedded or `instance_of`), else nil.
  @spec resource_type(Ash.Type.t(), Keyword.t()) :: {module(), boolean()} | nil
  def resource_type({:array, inner}, constraints) do
    case resource_type(inner, Keyword.get(constraints || [], :items, [])) do
      {resource, false} -> {resource, true}
      _ -> nil
    end
  end

  def resource_type(type, constraints) do
    type = Ash.Type.get_type(type)

    cond do
      is_atom(type) and Ash.Resource.Info.resource?(type) ->
        {type, false}

      type == Ash.Type.Struct and Ash.Resource.Info.resource?(constraints[:instance_of]) ->
        {constraints[:instance_of], false}

      true ->
        nil
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error({:unsupported, type, message}),
    do: "#{inspect(type)} has no protobuf mapping (#{message})"

  def format_error({:unresolved_resource, resource}),
    do: "#{inspect(resource)} has no message in the schema"

  def format_error(other), do: inspect(other)
end
