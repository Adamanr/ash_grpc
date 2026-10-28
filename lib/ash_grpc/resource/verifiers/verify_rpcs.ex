defmodule AshGrpc.Resource.Verifiers.VerifyRpcs do
  @moduledoc """
  Verifies rpcs: the action exists and its type fits the kind, `get_by` fields exist,
  kind-specific options are only used where they apply, `:bidi_stream` has a `handler`,
  custom request/response messages are valid, and action inputs/returns have a protobuf mapping.
  """

  use Spark.Dsl.Verifier

  alias AshGrpc.Resource.{Info, Rpc}
  alias AshGrpc.Resource.Verifiers.VerifyFields
  alias AshGrpc.Schema.Types
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    errors =
      case Info.rpcs(resource) do
        [] ->
          []

        [rpc | _] = rpcs ->
          if Ash.Resource.Info.embedded?(resource) do
            [error(resource, rpc, "embedded resources cannot declare rpcs")]
          else
            Enum.flat_map(rpcs, &verify_rpc(resource, &1))
          end
      end

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp verify_rpc(resource, rpc) do
    case Ash.Resource.Info.action(resource, rpc.action) do
      nil ->
        available = resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)

        [
          error(
            resource,
            rpc,
            "action #{inspect(rpc.action)} does not exist on #{inspect(resource)}. " <>
              "Available actions: #{inspect(available)}"
          )
        ]

      action ->
        case verify_kind(resource, rpc, action) do
          [] ->
            verify_get_by(resource, rpc, action) ++
              verify_options(resource, rpc) ++
              verify_messages(resource, rpc) ++
              verify_inputs(resource, rpc, action)

          errors ->
            errors
        end
    end
  end

  defp verify_kind(resource, rpc, action) do
    case Rpc.action_types(rpc.kind) do
      :any ->
        []

      types ->
        if action.type in types do
          []
        else
          [
            error(
              resource,
              rpc,
              "rpc kind #{inspect(rpc.kind)} requires a #{Enum.map_join(types, " or ", &inspect/1)} " <>
                "action, but #{inspect(action.name)} is a #{inspect(action.type)} action"
            )
          ]
        end
    end
  end

  defp verify_get_by(_resource, %Rpc{get_by: []}, _action), do: []

  defp verify_get_by(resource, %Rpc{kind: :get} = rpc, action) do
    arguments = Enum.map(action.arguments, & &1.name)

    for name <- rpc.get_by,
        !Ash.Resource.Info.attribute(resource, name) and name not in arguments do
      error(
        resource,
        rpc,
        "get_by field #{inspect(name)} is neither an attribute of #{inspect(resource)} " <>
          "nor an argument of action #{inspect(action.name)}"
      )
    end
  end

  defp verify_get_by(resource, rpc, _action),
    do: [
      error(
        resource,
        rpc,
        "`get_by` is only supported for `kind: :get`, got #{inspect(rpc.kind)}"
      )
    ]

  @kind_options [
    update_mask?: [:update],
    read_mask?: [:get, :list, :server_stream],
    filter?: [:list],
    return_destroyed?: [:destroy]
  ]

  defp verify_options(resource, rpc) do
    flags =
      for {option, kinds} <- @kind_options, Map.fetch!(rpc, option), rpc.kind not in kinds do
        error(
          resource,
          rpc,
          "`#{option}` is only supported for #{Enum.map_join(kinds, ", ", &inspect/1)} rpcs, " <>
            "got #{inspect(rpc.kind)}"
        )
      end

    wrapped =
      if rpc.input == :wrapped and rpc.kind not in [:create, :update, :client_stream] do
        [
          error(
            resource,
            rpc,
            "`input: :wrapped` is only supported for :create, :update and :client_stream rpcs"
          )
        ]
      else
        []
      end

    handler =
      cond do
        rpc.kind == :bidi_stream and is_nil(rpc.handler) ->
          [error(resource, rpc, "`kind: :bidi_stream` requires a `handler` module")]

        rpc.handler && match?({:error, _}, Code.ensure_compiled(rpc.handler)) ->
          [error(resource, rpc, "handler #{inspect(rpc.handler)} is not an available module")]

        true ->
          []
      end

    flags ++ wrapped ++ handler
  end

  defp verify_messages(resource, rpc) do
    Enum.flat_map([:request_message, :response_message], fn option ->
      verify_message(resource, rpc, option, Map.fetch!(rpc, option))
    end)
  end

  defp verify_message(_resource, _rpc, _option, nil), do: []

  defp verify_message(resource, rpc, option, name) when is_binary(name) do
    if Regex.match?(~r/^[A-Z][A-Za-z0-9]*$/, name) do
      []
    else
      [error(resource, rpc, "`#{option}` #{inspect(name)} must be a PascalCase message name")]
    end
  end

  defp verify_message(resource, rpc, option, module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :full_name, 0) and
         function_exported?(module, :__message_props__, 0) do
      []
    else
      [
        error(
          resource,
          rpc,
          "`#{option}` #{inspect(module)} is not a protobuf message module (`use Protobuf`)"
        )
      ]
    end
  end

  defp verify_inputs(resource, rpc, action) do
    arguments =
      for argument <- action.arguments, Map.get(argument, :public?, true) do
        {"argument #{inspect(argument.name)}", argument.type, argument.constraints, nil}
      end

    representations =
      Map.new(Info.field_configs(resource), &{&1.name, &1.representation})

    accepted =
      if action.type in [:create, :update] and rpc.input == :flat do
        for name <- action.accept || [],
            attribute = Ash.Resource.Info.attribute(resource, name) do
          {"accepted attribute #{inspect(name)}", attribute.type, attribute.constraints,
           representations[name]}
        end
      else
        []
      end

    returns =
      if action.type == :action and action.returns do
        [{"return type", action.returns, action.constraints, nil}]
      else
        []
      end

    for {what, type, constraints, representation} <- arguments ++ accepted ++ returns,
        {:error, reason} <- [
          Types.map(type, constraints,
            representation: representation,
            resolve_resource: &VerifyFields.placeholder/1
          )
        ] do
      error(
        resource,
        rpc,
        "#{what} of action #{inspect(action.name)}: #{Types.format_error(reason)}. " <>
          "Use a type with a mapping or implement AshGrpc.Type"
      )
    end
  end

  defp error(resource, rpc, message) do
    DslError.exception(
      module: resource,
      path: [:grpc, :rpc, rpc.name],
      message: message,
      location: Spark.Dsl.Entity.anno(rpc)
    )
  end
end
