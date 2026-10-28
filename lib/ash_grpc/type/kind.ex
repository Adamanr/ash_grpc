defmodule AshGrpc.Type.Kind do
  @moduledoc """
  Classifies an Ash type into the shape that drives its protobuf mapping.

  Shared by `AshGrpc.Type.Mapping` (schema side) and `AshGrpc.Codec` (value
  side) so both always agree. NewTypes are unwrapped (their constraints are
  merged) unless the NewType itself implements `AshGrpc.Type`.

  Kinds:

    * `{:custom, module, constraints}` – the type implements `AshGrpc.Type`
    * `{:array, item_type, item_constraints, array_constraints}`
    * `{:enum, values, enum_module | nil}` – `Ash.Type.Enum` or `:atom` with `one_of`
      (`enum_module` is the enum or NewType module that names the enum, `nil` when anonymous)
    * `{:resource, resource}` – embedded resource, or `:struct` with `instance_of` a resource
    * `{:fields, base_type, fields}` – `:map`/`:struct`/`:keyword`/`:tuple` with `fields`
    * `{:union, types}` – `Ash.Type.Union` (normalized `types` constraint)
    * `{:unsupported, type}` – `:term`, `:function`, `:file`, …
    * `{:basic, module, constraints}` – everything else (scalars, well-known types, untyped maps)
  """

  @type t ::
          {:custom, module(), Keyword.t()}
          | {:array, Ash.Type.t(), Keyword.t(), Keyword.t()}
          | {:enum, [atom() | String.t()], module() | nil}
          | {:resource, module()}
          | {:fields, module(), Keyword.t()}
          | {:union, Keyword.t()}
          | {:unsupported, module()}
          | {:basic, module(), Keyword.t()}

  @fields_types [Ash.Type.Map, Ash.Type.Struct, Ash.Type.Keyword, Ash.Type.Tuple]
  @unsupported [Ash.Type.Term, Ash.Type.Function, Ash.Type.File, Ash.Type.Range]

  @doc """
  Classifies `type` with `constraints`.

  With `skip_custom: module` the `AshGrpc.Type` implementation of that module
  is ignored (used by the codec when the type only implements `proto_type/1`).
  """
  @spec classify(Ash.Type.t(), Keyword.t(), Keyword.t()) :: t()
  def classify(type, constraints, opts \\ [])

  def classify({:array, inner}, constraints, _opts) do
    {:array, inner, Keyword.get(constraints || [], :items, []), constraints || []}
  end

  def classify(type, constraints, opts) do
    constraints = constraints || []
    type = Ash.Type.get_type(type)

    cond do
      not is_atom(type) -> {:unsupported, type}
      opts[:skip_custom] != type and custom?(type) -> {:custom, type, constraints}
      Ash.Type.NewType.new_type?(type) -> classify_new_type(type, constraints)
      true -> classify_module(type, constraints)
    end
  end

  defp classify_new_type(type, constraints) do
    type
    |> Ash.Type.NewType.subtype_of()
    |> classify(new_type_constraints(type, constraints))
    |> case do
      # a NewType of `:atom` + `one_of` is a named enum
      {:enum, values, nil} -> {:enum, values, type}
      kind -> kind
    end
  end

  defp classify_module(type, constraints) do
    cond do
      enum_module?(type) -> {:enum, type.values(), type}
      one_of?(type, constraints) -> {:enum, constraints[:one_of], nil}
      Ash.Resource.Info.resource?(type) -> {:resource, type}
      resource_struct?(type, constraints) -> {:resource, constraints[:instance_of]}
      fields?(type, constraints) -> {:fields, type, constraints[:fields]}
      true -> classify_basic(type, constraints)
    end
  end

  defp classify_basic(Ash.Type.Union, constraints),
    do: {:union, normalize_union_types(constraints[:types] || [])}

  defp classify_basic(type, _constraints) when type in @unsupported, do: {:unsupported, type}
  defp classify_basic(type, constraints), do: {:basic, type, constraints}

  defp one_of?(type, constraints), do: type == Ash.Type.Atom and is_list(constraints[:one_of])

  defp resource_struct?(type, constraints),
    do: type == Ash.Type.Struct and resource?(constraints[:instance_of]) and !constraints[:fields]

  defp fields?(type, constraints),
    do: type in @fields_types and is_list(constraints[:fields]) and constraints[:fields] != []

  @doc "True when the module implements the `AshGrpc.Type` behaviour."
  @spec custom?(module()) :: boolean()
  def custom?(type) do
    Code.ensure_loaded?(type) and function_exported?(type, :proto_type, 1)
  end

  @doc "True when the module is an `Ash.Type.Enum`."
  @spec enum_module?(module()) :: boolean()
  def enum_module?(type) do
    Code.ensure_loaded?(type) and function_exported?(type, :values, 0) and
      Spark.implements_behaviour?(type, Ash.Type.Enum)
  end

  @doc "Union member definitions as `[{name, type, constraints}]`, in declaration order."
  @spec union_members(Keyword.t()) :: [{atom(), Ash.Type.t(), Keyword.t()}]
  def union_members(types) do
    Enum.map(types, fn {name, config} ->
      {name, config[:type], config[:constraints] || []}
    end)
  end

  # constraints may be raw (not initialized), so merge in the NewType's own
  defp new_type_constraints(type, constraints) do
    case Ash.Type.init(type, constraints) do
      {:ok, initialized} -> Ash.Type.NewType.constraints(type, initialized)
      {:error, _} -> Ash.Type.NewType.constraints(type, constraints)
    end
  end

  defp resource?(module) when is_atom(module) and not is_nil(module),
    do: Ash.Resource.Info.resource?(module)

  defp resource?(_), do: false

  defp normalize_union_types(types) do
    Enum.map(types, fn {name, config} ->
      {name, Keyword.update(config, :type, nil, &Ash.Type.get_type/1)}
    end)
  end
end
