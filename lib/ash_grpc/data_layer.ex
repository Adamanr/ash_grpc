defmodule AshGrpc.DataLayer do
  @moduledoc """
  An Ash data layer backed by an external gRPC service.

      defmodule MyApp.Tickets.Ticket do
        use Ash.Resource, domain: MyApp.Tickets, data_layer: AshGrpc.DataLayer

        grpc_remote do
          client MyApp.TicketsClient                # a `use AshGrpc.Client` module
          message MyApp.Proto.Ticket                # the record message
          fields owner: "owner_id"                  # attribute => proto field (default: same name)

          read :list_tickets, filter: [:owner, :status]
          get :get_ticket, by: :id
          create :create_ticket, request: :ticket
          update :update_ticket, request: :ticket, update_mask: :update_mask
          destroy :delete_ticket
        end

        attributes do
          attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
          ...
        end
      end

  Policies, calculations, validations and code interfaces work as with any other data layer.

  ## Records

  Records are read from and written to the record message (`message`) through
  `AshGrpc.Codec`, using the attribute types: every attribute maps to the message field of the
  same name, or to the one given in `fields`; attributes without a field are `nil`. Enums are
  matched by value name (see `AshGrpc.DataLayer.Mapping`).

  ## Reads

    * Filters: equality filters (`attr == value`, also inside `and`) on the attributes listed in
      the read's `filter` option are sent as request fields. The whole filter is then applied in
      memory with `Ash.Filter.Runtime`, so every other filter still works — unless
      `strict_filters? true`, which makes reads with filters that cannot be pushed down fail with
      `AshGrpc.DataLayer.UnsupportedFilter`.
    * When a `get` rpc is declared and the filter has equality conditions on all of its `by`
      attributes (e.g. `Ash.get(Ticket, id)`), the get rpc is called instead. `NOT_FOUND` yields
      no record.
    * Pagination: with `paginate: :page_token` (the default) pages are requested with
      `page_size`/`page_token` and followed through `next_page_token` until the end, at most
      `max_pages` pages. Without a sort, reading stops once `offset + limit` matching records
      were found. Ash's offset and keyset pagination work on top of that.
    * Sorting, offset and limit are applied in memory.

  ## Writes

    * `create`/`update` send the record either as the request itself (its fields are the
      record's fields) or wrapped in the request field given by `request:`. Updates fill the
      `update_mask` field (a `google.protobuf.FieldMask`) with the proto names of the changed
      attributes. The response (or its `response:` field path) is the new record.
    * `destroy` sends the `by` attributes (default: the primary key); the response is ignored.

  There are no transactions: every action is one or more independent calls.

  ## Calls and errors

  Calls carry the actor and tenant (as call options for the client's `:metadata` function), the
  `metadata` of the section and its `deadline`, see `AshGrpc.DataLayer.Remote`. gRPC errors are
  mapped with `AshGrpc.Error.from_rpc_error/2`: `NOT_FOUND` on writes becomes
  `Ash.Error.Query.NotFound`, `INVALID_ARGUMENT` with `google.rpc.BadRequest` details becomes
  field errors on the attributes (also through a `request:` wrapper field).

  ## DSL

  See `AshGrpc.DataLayer.Info` for introspection.
  """

  @behaviour Ash.DataLayer

  use Spark.Dsl.Extension,
    sections: [AshGrpc.DataLayer.Dsl.section()],
    verifiers: [
      AshGrpc.DataLayer.Verifiers.VerifyClient,
      AshGrpc.DataLayer.Verifiers.VerifyRpcs,
      AshGrpc.DataLayer.Verifiers.VerifyFields
    ]

  require Logger

  alias AshGrpc.Client.RpcTable
  alias AshGrpc.DataLayer.{Filter, Info, Mapping, Operation, Remote}

  defmodule Query do
    @moduledoc "The data layer query of `AshGrpc.DataLayer`."
    defstruct [:resource, :domain, :filter, :limit, :tenant, sort: [], offset: 0, context: %{}]

    @type t :: %__MODULE__{
            resource: Ash.Resource.t(),
            domain: Ash.Domain.t() | nil,
            filter: Ash.Filter.t() | nil,
            limit: non_neg_integer() | nil,
            tenant: term(),
            sort: Ash.Sort.t(),
            offset: non_neg_integer(),
            context: map()
          }
  end

  defmodule UnsupportedFilter do
    @moduledoc """
    Returned by reads of `strict_filters? true` resources whose filter cannot be pushed down
    entirely to the rpc.
    """
    use Splode.Error, fields: [:resource, :rpc, :filter], class: :invalid

    @impl true
    def message(%{resource: resource, rpc: rpc, filter: filter}) do
      "#{inspect(resource)}: the filter #{inspect(filter)} cannot be sent to the rpc #{inspect(rpc)} (strict_filters? true)"
    end
  end

  # -- capabilities ------------------------------------------------------------------------

  @impl true
  @spec can?(Ash.Resource.t() | Spark.Dsl.t(), Ash.DataLayer.feature()) :: boolean()
  def can?(resource, :read),
    do: Info.operations(resource, :read) != [] or Info.operations(resource, :get) != []

  def can?(resource, :create), do: Info.operations(resource, :create) != []
  def can?(resource, :update), do: Info.operations(resource, :update) != []
  def can?(resource, :destroy), do: Info.operations(resource, :destroy) != []
  def can?(_, :filter), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, :nested_expressions), do: true
  def can?(_, {:filter_expr, _}), do: true
  def can?(_, :sort), do: true
  def can?(_, {:sort, _}), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :multitenancy), do: true
  def can?(_, :composite_primary_key), do: true
  def can?(_, :transact), do: false
  def can?(_, _), do: false

  # -- query building ----------------------------------------------------------------------

  @impl true
  def resource_to_query(resource, domain), do: %Query{resource: resource, domain: domain}

  @impl true
  def filter(%Query{filter: nil} = query, filter, _resource), do: {:ok, %{query | filter: filter}}

  def filter(%Query{} = query, filter, _resource),
    do: {:ok, %{query | filter: Ash.Filter.add_to_filter!(query.filter, filter)}}

  @impl true
  def sort(query, sort, _resource), do: {:ok, %{query | sort: sort}}

  @impl true
  def limit(query, limit, _resource), do: {:ok, %{query | limit: limit}}

  @impl true
  def offset(query, offset, _resource), do: {:ok, %{query | offset: offset || 0}}

  @impl true
  def set_tenant(_resource, query, tenant), do: {:ok, %{query | tenant: tenant}}

  @impl true
  def set_context(_resource, query, context), do: {:ok, %{query | context: context}}

  @impl true
  def select(query, _select, _resource), do: {:ok, query}

  # -- reads -------------------------------------------------------------------------------

  @impl true
  def run_query(%Query{resource: resource} = query, resource) do
    conditions = Filter.equalities(query.filter)
    ctx = call_context(resource, query.context, query.tenant, nil)

    case choose_read(resource, query, conditions) do
      {:get, op, pushed} ->
        with :ok <- check_strict(resource, op, query.filter, pushed),
             {:ok, records} <- run_get(resource, op, conditions, ctx) do
          finish(records, query)
        end

      {:read, op, pushed} ->
        with :ok <- check_strict(resource, op, query.filter, pushed) do
          run_list(resource, op, query, Map.take(conditions, pushed), ctx)
        end

      :error ->
        {:error,
         Ash.Error.Framework.AssumptionFailed.exception(
           message: "#{inspect(resource)} has no read rpc for #{inspect(action_name(query))}"
         )}
    end
  end

  defp action_name(%Query{context: context}), do: action_name(context[:action])
  defp action_name(%{name: name}), do: name
  defp action_name(name) when is_atom(name), do: name

  defp choose_read(resource, query, conditions) do
    get = Info.operation(resource, :get)
    get_by = get && by(resource, get)

    read = Info.read_operation(resource, action_name(query))

    cond do
      get && get_by != [] && Enum.all?(get_by, &Map.has_key?(conditions, &1)) ->
        {:get, get, get_by}

      read ->
        {:read, read,
         Enum.filter(Keyword.keys(filter_fields(resource, read)), &Map.has_key?(conditions, &1))}

      true ->
        :error
    end
  end

  defp check_strict(resource, op, filter, pushed) do
    if Info.grpc_remote_strict_filters?(resource) and not Filter.covered?(filter, pushed) do
      {:error, UnsupportedFilter.exception(resource: resource, rpc: op.rpc, filter: filter)}
    else
      :ok
    end
  end

  defp run_get(resource, op, conditions, ctx) do
    with {:ok, entry} <- entry(resource, op),
         {:ok, request} <- identity_request(resource, entry.request, by(resource, op), conditions) do
      resource |> client() |> Remote.call(op.rpc, request, ctx) |> get_result(resource, op)
    end
  end

  defp get_result({:ok, response}, resource, op) do
    with {:ok, record} <- response_record(resource, response, op.response),
         do: {:ok, List.wrap(record)}
  end

  defp get_result({:error, %GRPC.RPCError{status: 5}}, _resource, _op), do: {:ok, []}

  defp get_result({:error, error}, resource, _op),
    do: {:error, Remote.map_error(error, resource: resource)}

  defp run_list(resource, op, query, pushed, ctx) do
    with {:ok, entry} <- entry(resource, op),
         {:ok, base} <- filter_request(resource, op, entry.request, pushed) do
      wanted =
        if query.sort in [nil, []] and is_integer(query.limit),
          do: query.offset + query.limit,
          else: nil

      page_size =
        if wanted,
          do: min(wanted, Info.grpc_remote_page_size!(resource)),
          else: Info.grpc_remote_page_size!(resource)

      state = %{
        resource: resource,
        op: op,
        entry: entry,
        query: query,
        ctx: ctx,
        base: base,
        page_size: max(page_size, 1),
        wanted: wanted,
        max_pages: Info.grpc_remote_max_pages!(resource)
      }

      with {:ok, records} <- fetch_pages(state, "", 1, []) do
        finish_sorted(records, query)
      end
    end
  end

  # Fetches pages until the token runs out, `wanted` matching records were found or
  # `max_pages` pages were read. Records are filtered page by page.
  defp fetch_pages(state, token, page, acc) do
    request = page_request(state, token)

    with {:ok, response} <- list_call(state, request),
         {:ok, records} <- page_records(state, response),
         {:ok, matching} <- runtime_filter(records, state.query) do
      acc = acc ++ matching
      next = next_token(state, response)

      cond do
        state.wanted && length(acc) >= state.wanted ->
          {:ok, acc}

        next in [nil, ""] or state.op.paginate == :none ->
          {:ok, acc}

        page >= state.max_pages ->
          Logger.warning(
            "#{inspect(state.resource)}: stopped reading #{inspect(state.op.rpc)} after max_pages (#{state.max_pages}) pages"
          )

          {:ok, acc}

        true ->
          fetch_pages(state, next, page + 1, acc)
      end
    end
  end

  defp page_request(%{op: %Operation{paginate: :none}, base: base}, _token), do: base

  defp page_request(%{op: op, base: %module{} = base, page_size: page_size}, token) do
    base
    |> put_field(module, op.page_size_field, page_size)
    |> put_field(module, op.page_token_field, token)
  end

  defp put_field(struct, module, name, value) do
    case Mapping.field_key(module, name) do
      nil -> struct
      key -> Map.put(struct, key, value)
    end
  end

  defp list_call(state, request) do
    case Remote.call(client(state.resource), state.op.rpc, request, state.ctx) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, Remote.map_error(error, resource: state.resource)}
    end
  end

  defp page_records(%{resource: resource, op: op}, %module{} = response) do
    field = op.records || records_field_of(record_module(resource), module)

    response
    |> Mapping.get_path([field])
    |> List.wrap()
    |> map_ok(&to_record(resource, &1))
  end

  defp next_token(%{op: %Operation{paginate: :none}}, _response), do: nil
  defp next_token(%{op: op}, response), do: Mapping.get_path(response, [op.next_page_token_field])

  @doc """
  The first repeated field of `response_module` whose type is `record_module` (the default
  `records` field of reads), or `nil`.
  """
  @spec records_field_of(module(), module()) :: String.t() | nil
  def records_field_of(record_module, response_module) do
    Enum.find_value(
      response_module.__message_props__().field_props |> Enum.sort_by(&elem(&1, 0)),
      fn {_tag, props} -> if props.repeated? and props.type == record_module, do: props.name end
    )
  end

  defp finish(records, query) do
    with {:ok, records} <- runtime_filter(records, query), do: finish_sorted(records, query)
  end

  defp finish_sorted(records, query) do
    records =
      records
      |> Ash.Actions.Sort.runtime_sort(query.sort,
        domain: query.domain,
        tenant: query.tenant,
        rekey?: false
      )
      |> Enum.drop(query.offset || 0)

    {:ok, if(query.limit, do: Enum.take(records, query.limit), else: records)}
  end

  defp runtime_filter(records, %Query{filter: nil}), do: {:ok, records}

  defp runtime_filter(records, %Query{} = query) do
    Ash.Filter.Runtime.filter_matches(query.domain, records, query.filter,
      actor: query.context[:private][:actor],
      tenant: query.tenant
    )
  end

  # -- writes ------------------------------------------------------------------------------

  @impl true
  def create(resource, changeset) do
    op = Info.operation(resource, :create)

    with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, entry} <- entry(resource, op),
         {:ok, request} <- record_request(resource, op, entry.request, record) do
      write_call(resource, op, request, changeset)
    end
  end

  @impl true
  def update(resource, changeset) do
    op = Info.operation(resource, :update)

    with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, entry} <- entry(resource, op),
         {:ok, request} <- record_request(resource, op, entry.request, record) do
      request = put_update_mask(resource, op, request, changeset)
      write_call(resource, op, request, changeset)
    end
  end

  @impl true
  def destroy(resource, changeset) do
    op = Info.operation(resource, :destroy)
    by = by(resource, op)
    values = Map.new(by, &{&1, Map.get(changeset.data, &1)})

    with {:ok, entry} <- entry(resource, op),
         {:ok, request} <- identity_request(resource, entry.request, by, values) do
      ctx =
        call_context(
          resource,
          Map.put(changeset.context, :action, changeset.action),
          changeset.tenant,
          changeset.timeout
        )

      case Remote.call(client(resource), op.rpc, request, ctx) do
        {:ok, _response} ->
          :ok

        {:error, error} ->
          {:error,
           Remote.map_error(error,
             resource: resource,
             primary_key: values,
             message: Remote.bound_message(entry.request, specs(resource, entry.request))
           )}
      end
    end
  end

  defp write_call(resource, op, request, changeset) do
    ctx =
      call_context(
        resource,
        Map.put(changeset.context, :action, changeset.action),
        changeset.tenant,
        changeset.timeout
      )

    case Remote.call(client(resource), op.rpc, request, ctx) do
      {:ok, response} ->
        case response_record(resource, response, op.response) do
          {:ok, nil} -> {:error, "#{inspect(op.rpc)} returned no record"}
          other -> other
        end

      {:error, error} ->
        {:error, map_write_error(resource, op, request, changeset, error)}
    end
  end

  defp map_write_error(resource, op, %request_module{}, changeset, error) do
    pk = Ash.Resource.Info.primary_key(resource)

    opts = [
      resource: resource,
      primary_key: Map.new(pk, &{&1, Map.get(changeset.data || %{}, &1)})
    ]

    if op.request do
      names =
        Map.new(specs(resource, record_module(resource)), fn {proto, name, _, _} ->
          {proto, name}
        end)

      Remote.map_error(error, opts ++ [wrapper: op.request, names: names])
    else
      Remote.map_error(
        error,
        opts ++ [message: Remote.bound_message(request_module, specs(resource, request_module))]
      )
    end
  end

  defp put_update_mask(_resource, %Operation{update_mask: nil}, request, _changeset), do: request

  defp put_update_mask(resource, op, %module{} = request, changeset) do
    names =
      specs(resource, record_module(resource))
      |> Map.new(fn {proto, name, _, _} -> {name, proto} end)

    paths =
      changeset.attributes
      |> Map.keys()
      |> Enum.flat_map(fn attribute -> List.wrap(names[attribute]) end)
      |> Enum.sort()

    put_field(request, module, op.update_mask, %Google.Protobuf.FieldMask{paths: paths})
  end

  # -- requests and records ----------------------------------------------------------------

  # a request carrying the record: flat (the request's fields are record fields) or wrapped
  defp record_request(resource, %Operation{request: nil}, request_module, record),
    do: wrap_error(Mapping.encode(request_module, record, specs(resource, request_module)))

  defp record_request(resource, %Operation{request: field}, request_module, record) do
    module = record_module(resource)

    with {:ok, inner} <- wrap_error(Mapping.encode(module, record, specs(resource, module))) do
      {:ok, put_field(struct(request_module), request_module, field, inner)}
    end
  end

  # a request carrying the `by` attributes
  defp identity_request(resource, request_module, by, values) do
    specs = resource |> specs(request_module) |> Enum.filter(fn {_, name, _, _} -> name in by end)
    wrap_error(Mapping.encode(request_module, values, specs))
  end

  defp filter_request(resource, op, request_module, pushed) do
    fields = filter_fields(resource, op)

    specs =
      for {attribute, value} <- pushed,
          proto = Keyword.fetch!(fields, attribute),
          attr = Ash.Resource.Info.attribute(resource, attribute),
          not is_nil(value),
          do: {{proto, attribute, attr.type, attr.constraints}, value}

    wrap_error(
      Mapping.encode(
        request_module,
        Map.new(specs, fn {{_, name, _, _}, v} -> {name, v} end),
        Enum.map(specs, &elem(&1, 0))
      )
    )
  end

  defp filter_fields(resource, %Operation{filter: filter}) do
    Enum.map(filter, fn
      {attribute, field} -> {attribute, to_string(field)}
      attribute -> {attribute, Info.field_name(resource, attribute)}
    end)
  end

  defp response_record(resource, response, nil), do: to_record(resource, response)

  defp response_record(resource, response, path) do
    case Mapping.get_path(response, List.wrap(path)) do
      nil -> {:ok, nil}
      message -> to_record(resource, message)
    end
  end

  @doc false
  @spec to_record(Ash.Resource.t(), struct()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def to_record(resource, %module{} = message) do
    specs = specs(resource, module)
    present = Enum.map(specs, &elem(&1, 0))

    with {:ok, values} <- wrap_error(Mapping.decode(message, specs, present: present)),
         {:ok, attrs} <- cast_attributes(resource, values) do
      record = struct(resource, attrs)
      {:ok, %{record | __meta__: %Ecto.Schema.Metadata{state: :loaded, schema: resource}}}
    end
  end

  defp cast_attributes(resource, values) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce_while({:ok, %{}}, fn attribute, {:ok, acc} ->
      value = Map.get(values, attribute.name)

      case Ash.Type.cast_stored(attribute.type, value, attribute.constraints) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, attribute.name, value)}}
        {:error, error} -> {:halt, {:error, invalid_value(attribute, error)}}
      end
    end)
  end

  defp invalid_value(attribute, error) do
    Ash.Error.Changes.InvalidAttribute.exception(
      field: attribute.name,
      message: "invalid value returned by the remote service: %{error}",
      vars: [error: inspect(error)]
    )
  end

  @doc """
  The binding specs (see `AshGrpc.DataLayer.Mapping`) of the resource's attributes for the
  fields of the protobuf `module`.
  """
  @spec specs(Ash.Resource.t(), module()) :: [Mapping.spec()]
  def specs(resource, module) do
    names = MapSet.new(Mapping.field_names(module))

    for attribute <- Ash.Resource.Info.attributes(resource),
        proto = Info.field_name(resource, attribute.name),
        MapSet.member?(names, proto),
        do: {proto, attribute.name, attribute.type, attribute.constraints}
  end

  # -- helpers -----------------------------------------------------------------------------

  defp client(resource), do: Info.grpc_remote_client!(resource)
  defp record_module(resource), do: Info.grpc_remote_message!(resource)

  defp by(_resource, %Operation{by: by}) when by not in [nil, []], do: by
  defp by(resource, _op), do: Ash.Resource.Info.primary_key(resource)

  @doc false
  @spec entry(Ash.Resource.t(), Operation.t()) :: {:ok, RpcTable.Entry.t()} | {:error, term()}
  def entry(resource, %Operation{rpc: rpc}), do: rpc_entry(client(resource), rpc)

  @doc """
  Resolves `rpc` of `client` to its `AshGrpc.Client.RpcTable.Entry` (from the compiled table of
  `use AshGrpc.Client` modules, else from the running client).
  """
  @spec rpc_entry(AshGrpc.Client.client(), AshGrpc.Client.rpc()) ::
          {:ok, RpcTable.Entry.t()} | {:error, Exception.t()}
  def rpc_entry(client, rpc) do
    table =
      if Code.ensure_loaded?(client) and function_exported?(client, :__rpc_table__, 0) do
        {:ok, client.__rpc_table__()}
      else
        with {:ok, runtime} <- AshGrpc.Client.Runtime.fetch(client), do: {:ok, runtime.table}
      end

    with {:ok, table} <- table, do: RpcTable.fetch(table, rpc)
  end

  defp call_context(resource, context, tenant, timeout) do
    private = (context || %{})[:private] || %{}

    %{
      actor: private[:actor],
      tenant: tenant || private[:tenant],
      resource: resource,
      action: action_name(context[:action] || private[:action_name]),
      context: context || %{},
      deadline: Info.option(resource, :deadline) || timeout_ms(timeout),
      metadata: Info.option(resource, :metadata)
    }
  end

  defp timeout_ms(timeout) when is_integer(timeout), do: timeout
  defp timeout_ms(_), do: nil

  defp wrap_error({:ok, value}), do: {:ok, value}
  defp wrap_error({:error, %{__exception__: true} = error}), do: {:error, error}

  defp wrap_error({:error, reason}),
    do:
      {:error,
       Ash.Error.Framework.AssumptionFailed.exception(
         message: "gRPC codec error: #{inspect(reason)}"
       )}

  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
