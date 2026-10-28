defmodule AshGrpc.Resource.Info do
  @moduledoc """
  Introspection for `AshGrpc.Resource`.

  Besides the generated `grpc_*` accessors, it provides resolved views: `message_name/1`
  (default applied), `fields/1` (effective message fields) and `rpcs/1` (kinds and `get_by`
  resolved).
  """

  use Spark.InfoGenerator, extension: AshGrpc.Resource, sections: [:grpc]

  alias AshGrpc.Resource.{Field, Reserved, Rpc}

  defmodule MessageField do
    @moduledoc """
    A resolved field of a resource message.

    `kind` tells where the value comes from; `config` is the `field` entity tuning it (if any).
    For relationships `type` is the destination resource and `cardinality` is `:one | :many`.
    """
    defstruct [
      :name,
      :proto_name,
      :kind,
      :type,
      :constraints,
      :description,
      :cardinality,
      :config,
      allow_nil?: true
    ]

    @type t :: %__MODULE__{
            name: atom(),
            proto_name: String.t(),
            kind: :attribute | :calculation | :aggregate | :relationship,
            type: Ash.Type.t() | module(),
            constraints: Keyword.t(),
            description: String.t() | nil,
            cardinality: :one | :many | nil,
            config: AshGrpc.Resource.Field.t() | nil,
            allow_nil?: boolean()
          }
  end

  @doc "Returns true if the resource uses the `AshGrpc.Resource` extension."
  @spec grpc?(module()) :: boolean()
  def grpc?(resource) do
    is_atom(resource) and Code.ensure_loaded?(resource) and
      function_exported?(resource, :spark_dsl_config, 0) and
      AshGrpc.Resource in Spark.extensions(resource)
  end

  @doc "The message name (default: last segment of the module name)."
  @spec message_name(module()) :: String.t()
  def message_name(resource) do
    case grpc?(resource) && grpc_message(resource) do
      {:ok, name} -> name
      _ -> resource |> Module.split() |> List.last()
    end
  end

  @doc "The `field` entities."
  @spec field_configs(module()) :: [Field.t()]
  def field_configs(resource) do
    if grpc?(resource), do: Enum.filter(grpc(resource), &is_struct(&1, Field)), else: []
  end

  @doc "The `reserved` entities."
  @spec reserved(module()) :: [Reserved.t()]
  def reserved(resource) do
    if grpc?(resource), do: Enum.filter(grpc(resource), &is_struct(&1, Reserved)), else: []
  end

  @doc "Reserved numbers of the message (IR form)."
  @spec reserved_numbers(module()) :: [AshGrpc.Proto.IR.reserved_number()]
  def reserved_numbers(resource), do: resource |> reserved() |> Enum.flat_map(&Reserved.to_ir/1)

  @doc "Reserved names of the message."
  @spec reserved_names(module()) :: [String.t()]
  def reserved_names(resource) do
    resource |> reserved() |> Enum.flat_map(& &1.names) |> Enum.map(&to_string/1)
  end

  @doc "The names of the fields that make up the message (default: public attributes)."
  @spec field_names(module()) :: [atom()]
  def field_names(resource) do
    case grpc?(resource) && grpc_fields(resource) do
      {:ok, names} -> names
      _ -> resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
    end
  end

  @doc """
  The resolved message fields. Unknown names are skipped (the verifier reports them).
  """
  @spec fields(module()) :: [MessageField.t()]
  def fields(resource) do
    configs = Map.new(field_configs(resource), &{&1.name, &1})

    resource
    |> field_names()
    |> Enum.flat_map(fn name ->
      case message_field(resource, name, configs[name]) do
        nil -> []
        field -> [field]
      end
    end)
  end

  @doc "A resolved message field by Ash name."
  @spec field(module(), atom()) :: MessageField.t() | nil
  def field(resource, name), do: Enum.find(fields(resource), &(&1.name == name))

  @doc """
  Fields loaded by default for responses: calculations and aggregates that are part of the message.
  Relationships are only loaded when the rpc `load` asks for them.
  """
  @spec default_load(module()) :: [atom()]
  def default_load(resource) do
    for %MessageField{kind: kind, name: name} <- fields(resource),
        kind in [:calculation, :aggregate],
        do: name
  end

  @doc "Default proto name for an Ash field name (trailing `?`/`!` removed)."
  @spec default_proto_name(atom()) :: String.t()
  def default_proto_name(name),
    do: name |> to_string() |> String.trim_trailing("?") |> String.trim_trailing("!")

  defp message_field(resource, name, config) do
    base = %MessageField{
      name: name,
      config: config,
      proto_name: (config && config.proto_name) || default_proto_name(name)
    }

    cond do
      attribute = Ash.Resource.Info.attribute(resource, name) ->
        %{
          base
          | kind: :attribute,
            type: attribute.type,
            constraints: attribute.constraints,
            description: attribute.description,
            allow_nil?: attribute.allow_nil?
        }

      calculation = Ash.Resource.Info.calculation(resource, name) ->
        %{
          base
          | kind: :calculation,
            type: calculation.type,
            constraints: calculation.constraints,
            description: calculation.description,
            allow_nil?: calculation.allow_nil?
        }

      aggregate = Ash.Resource.Info.aggregate(resource, name) ->
        {type, constraints} = aggregate_type(resource, aggregate)

        %{
          base
          | kind: :aggregate,
            type: type,
            constraints: constraints,
            description: aggregate.description,
            allow_nil?: aggregate_allow_nil?(aggregate)
        }

      relationship = Ash.Resource.Info.relationship(resource, name) ->
        %{
          base
          | kind: :relationship,
            type: relationship.destination,
            constraints: [],
            description: relationship.description,
            cardinality: relationship.cardinality,
            allow_nil?: relationship.cardinality == :one
        }

      true ->
        nil
    end
  end

  defp aggregate_type(resource, aggregate) do
    case Ash.Query.Aggregate.aggregate_type(resource, aggregate) do
      {:ok, type, constraints} -> {type, constraints || []}
      _ -> {aggregate.type, aggregate.constraints || []}
    end
  end

  defp aggregate_allow_nil?(%{kind: kind}) when kind in [:count, :exists], do: false
  defp aggregate_allow_nil?(_aggregate), do: true

  @doc "The `rpc` entities with `kind` and `get_by` resolved."
  @spec rpcs(module()) :: [Rpc.t()]
  def rpcs(resource) do
    if grpc?(resource) do
      grpc(resource) |> Enum.filter(&is_struct(&1, Rpc)) |> Enum.map(&resolve_rpc(resource, &1))
    else
      []
    end
  end

  @doc "A resolved rpc by DSL name."
  @spec rpc(module(), atom()) :: Rpc.t() | nil
  def rpc(resource, name), do: Enum.find(rpcs(resource), &(&1.name == name))

  defp resolve_rpc(resource, %Rpc{} = rpc) do
    case Ash.Resource.Info.action(resource, rpc.action) do
      nil ->
        rpc

      action ->
        kind = rpc.kind || Rpc.default_kind(action, rpc.get_by)
        %{rpc | kind: kind, get_by: resolve_get_by(resource, action, kind, rpc.get_by)}
    end
  end

  defp resolve_get_by(_resource, _action, _kind, get_by) when is_list(get_by), do: get_by

  defp resolve_get_by(resource, %{type: :read} = action, :get, nil) do
    if Map.get(action, :get?), do: [], else: Ash.Resource.Info.primary_key(resource)
  end

  defp resolve_get_by(_resource, _action, _kind, nil), do: []
end
