defmodule AshGrpc.DataLayer.Verifiers.VerifyFields do
  @moduledoc """
  Verifies that the fields referenced by `grpc_remote` exist on the messages:

    * `fields` – on the record message,
    * `read` – `filter` fields on the request, `records` (or a repeated field of the record
      message type) and, with `paginate: :page_token`, the page fields,
    * `get` / `destroy` – the `by` attributes on the request,
    * `create` / `update` – the `request` wrapper field (or, for flat requests, at least one
      record field), the `update_mask` field and the `response` path.
  """
  use Spark.Dsl.Verifier

  alias AshGrpc.DataLayer.Verifiers.VerifyClient
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    client = Verifier.get_option(dsl_state, [:grpc_remote], :client)
    message = Verifier.get_option(dsl_state, [:grpc_remote], :message)
    fields = Verifier.get_option(dsl_state, [:grpc_remote], :fields) || []

    if VerifyClient.client_module?(client) and protobuf?(message) do
      ctx = %{
        module: module,
        client: client,
        message: message,
        fields: fields,
        dsl_state: dsl_state
      }

      with :ok <- verify_record_fields(ctx) do
        dsl_state
        |> Verifier.get_entities([:grpc_remote])
        |> first_error(&verify_operation(ctx, &1))
      end
    else
      # reported by VerifyClient
      :ok
    end
  end

  defp verify_record_fields(ctx) do
    names = names(ctx.message)

    case Enum.find(ctx.fields, fn {_attribute, field} -> to_string(field) not in names end) do
      nil ->
        :ok

      {attribute, field} ->
        error(
          ctx,
          [:grpc_remote, :fields, attribute],
          "#{inspect(ctx.message)} has no field #{inspect(field)}"
        )
    end
  end

  defp verify_operation(ctx, op) do
    case AshGrpc.Client.RpcTable.fetch(ctx.client.__rpc_table__(), op.rpc) do
      {:ok, entry} -> verify_kind(ctx, op, entry)
      # reported by VerifyRpcs
      {:error, _} -> :ok
    end
  end

  defp verify_kind(ctx, %{kind: :read} = op, entry) do
    filter_fields =
      Enum.map(op.filter, fn
        {_attribute, field} -> field
        attribute -> field_name(ctx, attribute)
      end)

    page_fields =
      if op.paginate == :page_token,
        do: [
          {entry.request, op.page_size_field},
          {entry.request, op.page_token_field},
          {entry.response, op.next_page_token_field}
        ],
        else: []

    records =
      if op.records do
        [{entry.response, op.records}]
      else
        []
      end

    with :ok <-
           fields_exist(
             ctx,
             op,
             Enum.map(filter_fields, &{entry.request, &1}) ++ page_fields ++ records
           ) do
      if op.records || AshGrpc.DataLayer.records_field_of(ctx.message, entry.response) do
        :ok
      else
        error(
          ctx,
          path(op),
          "#{inspect(entry.response)} has no repeated #{inspect(ctx.message)} field; set `records`"
        )
      end
    end
  end

  defp verify_kind(ctx, %{kind: kind} = op, entry) when kind in [:get, :destroy] do
    by = if op.by in [nil, []], do: primary_key(ctx), else: op.by

    with :ok <- fields_exist(ctx, op, Enum.map(by, &{entry.request, field_name(ctx, &1)})) do
      verify_response(ctx, op, entry)
    end
  end

  defp verify_kind(ctx, op, entry) do
    request_fields =
      if op.request do
        [{entry.request, op.request}]
      else
        []
      end

    mask = if op.update_mask, do: [{entry.request, op.update_mask}], else: []

    with :ok <- fields_exist(ctx, op, request_fields ++ mask) do
      verify_response(ctx, op, entry)
    end
  end

  defp verify_response(_ctx, %{kind: :destroy}, _entry), do: :ok
  defp verify_response(_ctx, %{response: nil}, _entry), do: :ok

  defp verify_response(ctx, op, entry) do
    op.response
    |> List.wrap()
    |> Enum.reduce_while({:ok, entry.response}, fn field, {:ok, module} ->
      case field_props(module, field) do
        %{embedded?: true, type: type} ->
          {:cont, {:ok, type}}

        _ ->
          {:halt,
           error(
             ctx,
             path(op),
             "#{inspect(module)} has no message field #{inspect(field)} (response path)"
           )}
      end
    end)
    |> case do
      {:ok, _module} -> :ok
      error -> error
    end
  end

  defp fields_exist(ctx, op, pairs) do
    case Enum.find(pairs, fn {module, field} -> is_nil(field_props(module, field)) end) do
      nil ->
        :ok

      {module, field} ->
        error(ctx, path(op), "#{inspect(module)} has no field #{inspect(to_string(field))}")
    end
  end

  defp field_props(module, field) do
    field = to_string(field)

    Enum.find_value(module.__message_props__().field_props, fn {_tag, props} ->
      if props.name == field, do: props
    end)
  end

  defp names(module), do: AshGrpc.DataLayer.Mapping.field_names(module)

  defp field_name(ctx, attribute) do
    case Keyword.fetch(ctx.fields, attribute) do
      {:ok, field} -> to_string(field)
      :error -> to_string(attribute)
    end
  end

  defp primary_key(ctx) do
    ctx.dsl_state
    |> Verifier.get_entities([:attributes])
    |> Enum.filter(&Map.get(&1, :primary_key?))
    |> Enum.map(& &1.name)
  end

  defp protobuf?(message) do
    is_atom(message) and Code.ensure_loaded?(message) and
      function_exported?(message, :__message_props__, 0)
  end

  defp path(op), do: [:grpc_remote, op.kind, op.rpc]

  defp error(ctx, path, message) do
    {:error, Spark.Error.DslError.exception(module: ctx.module, path: path, message: message)}
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
