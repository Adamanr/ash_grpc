defmodule AshGrpc.Rpc do
  @options_schema [
    client: [type: :atom, required: true, doc: "The `AshGrpc.Client` to call."],
    rpc: [
      type: {:or, [:atom, :string]},
      required: true,
      doc: "The rpc (any name accepted by `AshGrpc.Client.RpcTable`)."
    ],
    request: [
      type: {:or, [{:fun, 1}, {:fun, 2}, nil]},
      doc: "Builds the request from the action input (see \"Request\")."
    ],
    response: [
      type: {:or, [:atom, :string, {:list, {:or, [:atom, :string]}}, {:fun, 1}, {:fun, 2}, nil]},
      doc: "Field path of the result, or a function (see \"Response\")."
    ],
    metadata: [
      type: {:or, [{:fun, 1}, :mfa, :map, nil]},
      doc:
        "Extra metadata: a map, or a function / `{m, f, a}` of `%{actor:, tenant:, resource:, action:, context:}`."
    ],
    deadline: [type: {:or, [:pos_integer, nil]}, doc: "Deadline of the call in milliseconds."]
  ]

  @moduledoc """
  A generic action implementation calling a unary rpc of an `AshGrpc.Client`.

      action :escalate, :map do
        argument :ticket_id, :string, allow_nil?: false
        argument :level, :integer, default: 1
        run {AshGrpc.Rpc, client: MyApp.Tickets, rpc: :escalate}
      end

      action :charge, :struct do
        constraints instance_of: MyApp.Charge
        argument :amount, :integer, allow_nil?: false
        run {AshGrpc.Rpc,
             client: MyApp.Billing,
             rpc: :charge,
             request: &%{amount: &1.arguments.amount},
             response: :charge}
      end

  ## Options

  #{Spark.Options.docs(@options_schema)}

  ## Request

  By default every argument whose name matches a request field (proto name) is sent in that
  field, converted with `AshGrpc.Codec` according to the argument's type (timestamps, enums,
  nested maps, …). With `request:` a function builds the request from the `Ash.ActionInput`
  (and, with arity 2, the `Ash.Resource.Actions.Implementation.Context`); it returns the request
  struct or a map/keyword list of protobuf values (nested maps become structs).

  ## Response

  The response is decoded into the action's return type:

    * `response: nil` (default) – the whole response message,
    * `response: :field` / `[:field, :nested]` – the value at that field path,
    * `response: fun` – `fun.(response)` or `fun.(response, input)` returns the result
      (`{:ok, value}`, `{:error, error}` or a plain value).

  Messages decoded into a resource or embedded resource type (also `:struct` with
  `instance_of`) are mapped by attribute name; other messages become maps keyed by proto field
  names (atoms); scalars and lists are converted using the return type. The value is then cast
  with `Ash.Type.cast_input/3`. Actions without a return type return `:ok`.

  ## Metadata, deadline, errors

  The actor and tenant are passed to the client as call options (`:actor`, `:tenant`), so the
  client's `:metadata` function can turn them into headers; `metadata:` adds metadata derived
  from the call context (see `AshGrpc.DataLayer.Remote`). The deadline is `deadline:`, else the
  domain timeout when it is an integer, else the client's default (always capped by a
  propagated deadline, see `AshGrpc.Client.put_deadline/1`).

  gRPC errors are mapped with `AshGrpc.Error.from_rpc_error/2`; `google.rpc.BadRequest` field
  violations are reported on the arguments mapped to the violated request fields.
  """

  use Ash.Resource.Actions.Implementation

  alias AshGrpc.DataLayer.{Foreign, Mapping, Remote}
  alias AshGrpc.Proto.IR

  @impl true
  def run(input, opts, context) do
    opts = Spark.Options.validate!(opts, @options_schema)

    with {:ok, entry} <- AshGrpc.DataLayer.rpc_entry(opts[:client], opts[:rpc]),
         {:ok, request} <- build_request(input, context, entry.request, opts[:request]) do
      ctx = %{
        actor: context.actor,
        tenant: context.tenant,
        resource: input.resource,
        action: input.action.name,
        context: input.context,
        deadline: opts[:deadline] || domain_timeout(context.domain || input.domain),
        metadata: opts[:metadata]
      }

      case Remote.call(opts[:client], opts[:rpc], request, ctx) do
        {:ok, response} ->
          handle_response(response, input, opts[:response])

        {:error, error} ->
          {:error,
           Remote.map_error(error,
             resource: input.resource,
             message: Remote.bound_message(entry.request, argument_specs(input, entry.request))
           )}
      end
    end
  end

  # -- request -----------------------------------------------------------------------------

  defp build_request(input, _context, request_module, nil) do
    case Mapping.encode(request_module, input.arguments, argument_specs(input, request_module)) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, codec_error(reason)}
    end
  end

  defp build_request(input, _context, _module, fun) when is_function(fun, 1),
    do: request_result(fun.(input))

  defp build_request(input, context, _module, fun) when is_function(fun, 2),
    do: request_result(fun.(input, context))

  defp request_result({:ok, request}), do: {:ok, request}
  defp request_result({:error, error}), do: {:error, error}
  defp request_result(request), do: {:ok, request}

  defp argument_specs(input, request_module) do
    names = MapSet.new(Mapping.field_names(request_module))

    for argument <- input.action.arguments,
        proto = to_string(argument.name),
        MapSet.member?(names, proto),
        do: {proto, argument.name, argument.type, argument.constraints}
  end

  # -- response ----------------------------------------------------------------------------

  defp handle_response(response, _input, fun) when is_function(fun, 1),
    do: response_result(fun.(response))

  defp handle_response(response, input, fun) when is_function(fun, 2),
    do: response_result(fun.(response, input))

  defp handle_response(_response, %{action: %{returns: nil}}, _path), do: :ok

  defp handle_response(%module{} = response, input, path) do
    path = List.wrap(path)
    %{returns: type, constraints: constraints} = input.action

    with {:ok, value} <- decode_path(response, module, path, type, constraints || []) do
      case Ash.Type.cast_input(type, value, constraints || []) do
        {:ok, value} -> {:ok, value}
        {:error, error} -> {:error, invalid_response(error)}
      end
    end
  end

  defp response_result({:ok, value}), do: {:ok, value}
  defp response_result({:error, error}), do: {:error, error}
  defp response_result(:ok), do: :ok
  defp response_result(value), do: {:ok, value}

  defp decode_path(response, _module, [], type, constraints),
    do: decode_value(response, nil, nil, type, constraints)

  defp decode_path(response, module, path, type, constraints) do
    with {:ok, field, schema} <- path_field(module, path) do
      decode_value(Mapping.get_path(response, path), field, schema, type, constraints)
    end
  end

  # the IR field at the end of the path, and the schema of its message
  defp path_field(module, [name]) do
    with {:ok, message, schema} <- Foreign.message(module) do
      case Mapping.field(message, name) do
        nil -> {:error, codec_error({:unknown_field, module, name})}
        field -> {:ok, field, schema}
      end
    end
  end

  defp path_field(module, [name | rest]) do
    case module.__message_props__().field_props
         |> Map.values()
         |> Enum.find(&(&1.name == to_string(name))) do
      %{embedded?: true, type: type} -> path_field(type, rest)
      _ -> {:error, codec_error({:unknown_field, module, name})}
    end
  end

  defp decode_value(nil, _field, _schema, _type, _constraints), do: {:ok, nil}

  defp decode_value(%module{} = message, _field, _schema, type, constraints) do
    if function_exported?(module, :__message_props__, 0) do
      decode_message(message, record_type(type, constraints))
    else
      {:ok, message}
    end
  end

  defp decode_value(value, %IR.Field{} = field, schema, type, constraints) do
    case Mapping.decode_value(value, field, schema, type, constraints) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, codec_error(reason)}
    end
  end

  defp decode_value(value, nil, _schema, _type, _constraints), do: {:ok, value}

  defp decode_message(message, nil) do
    case Mapping.decode(message, natural_specs(message)) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, codec_error(reason)}
    end
  end

  defp decode_message(message, resource) do
    case AshGrpc.DataLayer.to_record(resource, message) do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, codec_error(reason)}
    end
  end

  # every field under its own name, converted naturally
  defp natural_specs(%module{}) do
    for {_tag, props} <- module.__message_props__().field_props,
        do: {props.name, props.name_atom, nil, []}
  end

  defp record_type(type, constraints) do
    type = Ash.Type.get_type(type)

    cond do
      is_atom(type) and Ash.Resource.Info.resource?(type) ->
        type

      type == Ash.Type.Struct and is_atom(constraints[:instance_of]) and
          Ash.Resource.Info.resource?(constraints[:instance_of]) ->
        constraints[:instance_of]

      true ->
        nil
    end
  end

  defp domain_timeout(nil), do: nil

  defp domain_timeout(domain) do
    case Ash.Domain.Info.timeout(domain) do
      timeout when is_integer(timeout) -> timeout
      _ -> nil
    end
  end

  defp invalid_response(error) do
    Ash.Error.Framework.AssumptionFailed.exception(
      message: "the rpc response cannot be cast to the action's return type: #{inspect(error)}"
    )
  end

  defp codec_error(%{__exception__: true} = error), do: error

  defp codec_error(reason),
    do:
      Ash.Error.Framework.AssumptionFailed.exception(
        message: "gRPC codec error: #{inspect(reason)}"
      )
end
