defmodule AshGrpc.Resource.Verifiers.VerifyFields do
  @moduledoc """
  Verifies the resource message: listed fields exist, `field` entities refer to message fields,
  proto names are valid and unique, numbers are valid, unique and not reserved, relationship
  destinations use `AshGrpc.Resource`, and every type has a protobuf mapping (or a
  `representation`).
  """

  use Spark.Dsl.Verifier

  alias AshGrpc.Resource.{Field, Info, Reserved}
  alias AshGrpc.Schema.Types
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @max_number 536_870_911

  @impl true
  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    errors =
      verify_listed(resource, dsl_state) ++
        verify_configs(resource) ++
        verify_reserved(resource) ++
        verify_names(resource) ++
        verify_numbers(resource) ++
        verify_types(resource)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp verify_listed(resource, dsl_state) do
    case Info.grpc_fields(resource) do
      {:ok, names} ->
        anno = Spark.Dsl.Extension.get_opt_anno(dsl_state, [:grpc], :fields)

        duplicates = names -- Enum.uniq(names)

        dup_errors =
          for name <- Enum.uniq(duplicates) do
            error(
              resource,
              [:grpc, :fields],
              "field #{inspect(name)} is listed more than once",
              anno
            )
          end

        missing_errors =
          for name <- names, !Ash.Resource.Info.field(resource, name) do
            error(
              resource,
              [:grpc, :fields],
              "#{inspect(name)} is not an attribute, calculation, aggregate or relationship of #{inspect(resource)}",
              anno
            )
          end

        dup_errors ++ missing_errors

      :error ->
        []
    end
  end

  defp verify_configs(resource) do
    names = Info.field_names(resource)

    for %Field{name: name} = config <- Info.field_configs(resource), name not in names do
      error(
        resource,
        [:grpc, :field, name],
        "field #{inspect(name)} is not part of the message. Message fields: #{inspect(names)} " <>
          "(add it to `fields` to expose it)",
        Spark.Dsl.Entity.anno(config)
      )
    end
  end

  defp verify_reserved(resource) do
    for %Reserved{} = reserved <- Info.reserved(resource),
        number <- reserved.numbers,
        !valid_reserved?(number) do
      error(
        resource,
        [:grpc, :reserved],
        "invalid reserved number #{inspect(number)}: expected a positive integer, a range or {from, :max}",
        Spark.Dsl.Entity.anno(reserved)
      )
    end
  end

  defp valid_reserved?(number) when is_integer(number), do: number in 1..@max_number//1

  defp valid_reserved?(%Range{first: first, last: last, step: 1}),
    do: first >= 1 and last >= first

  defp valid_reserved?({first, :max}) when is_integer(first), do: first >= 1

  defp valid_reserved?({first, last}) when is_integer(first) and is_integer(last),
    do: first >= 1 and last >= first

  defp valid_reserved?(_), do: false

  defp verify_names(resource) do
    fields = Info.fields(resource)
    reserved_names = Info.reserved_names(resource)

    invalid =
      for field <- fields, !Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, field.proto_name) do
        field_error(
          resource,
          field,
          "#{inspect(field.proto_name)} is not a valid proto field name (use `proto_name:`)"
        )
      end

    duplicates =
      fields
      |> Enum.group_by(& &1.proto_name)
      |> Enum.filter(fn {_, fields} -> length(fields) > 1 end)
      |> Enum.map(fn {proto_name, [field | _] = fields} ->
        field_error(
          resource,
          field,
          "proto field name #{inspect(proto_name)} is used by #{inspect(Enum.map(fields, & &1.name))}"
        )
      end)

    reserved =
      for field <- fields, field.proto_name in reserved_names do
        field_error(resource, field, "proto field name #{inspect(field.proto_name)} is reserved")
      end

    invalid ++ duplicates ++ reserved
  end

  defp verify_numbers(resource) do
    reserved_numbers = Info.reserved_numbers(resource)
    numbered = for field <- Info.fields(resource), field.config && field.config.number, do: field

    individual =
      Enum.flat_map(numbered, fn field ->
        number = field.config.number

        cond do
          number > @max_number ->
            [
              field_error(
                resource,
                field,
                "field number #{number} is above the maximum #{@max_number}"
              )
            ]

          number in 19_000..19_999 ->
            [
              field_error(
                resource,
                field,
                "field number #{number} is in 19000..19999, which is reserved by the protobuf implementation"
              )
            ]

          Enum.any?(reserved_numbers, &Reserved.reserved?(&1, number)) ->
            [field_error(resource, field, "field number #{number} is reserved")]

          true ->
            []
        end
      end)

    duplicates =
      numbered
      |> Enum.group_by(& &1.config.number)
      |> Enum.filter(fn {_, fields} -> length(fields) > 1 end)
      |> Enum.map(fn {number, [_ | [field | _]] = fields} ->
        field_error(
          resource,
          field,
          "field number #{number} is used by #{inspect(Enum.map(fields, & &1.name))}"
        )
      end)

    individual ++ duplicates
  end

  defp verify_types(resource) do
    Enum.flat_map(Info.fields(resource), fn
      %{kind: :relationship, type: destination} = field ->
        if Info.grpc?(destination) do
          []
        else
          [
            field_error(
              resource,
              field,
              "relationship #{inspect(field.name)} points to #{inspect(destination)}, " <>
                "which does not use the AshGrpc.Resource extension"
            )
          ]
        end

      field ->
        opts = [
          allow_nil?: field.allow_nil?,
          name_hint: Macro.camelize(to_string(field.name)),
          representation: field.config && field.config.representation,
          resolve_resource: &placeholder/1
        ]

        case Types.map(field.type, field.constraints, opts) do
          {:ok, _} ->
            []

          {:error, reason} ->
            [
              field_error(
                resource,
                field,
                "#{inspect(field.name)}: #{Types.format_error(reason)}. Set `representation:` " <>
                  "in `field #{inspect(field.name)}, ...` or implement AshGrpc.Type"
              )
            ]
        end
    end)
  end

  @doc false
  def placeholder(resource) do
    if Ash.Resource.Info.embedded?(resource) or Info.grpc?(resource),
      do: "ash_grpc.verifier.Placeholder"
  end

  defp field_error(resource, %Info.MessageField{config: nil, name: name}, message),
    do: error(resource, [:grpc, :fields, name], message, nil)

  defp field_error(resource, %Info.MessageField{config: config, name: name}, message),
    do: error(resource, [:grpc, :field, name], message, Spark.Dsl.Entity.anno(config))

  defp error(resource, path, message, anno) do
    DslError.exception(module: resource, path: path, message: message, location: anno)
  end
end
