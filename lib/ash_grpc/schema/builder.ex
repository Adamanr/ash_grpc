defmodule AshGrpc.Schema.Builder do
  @moduledoc false
  # Builds one IR file per domain. Numbers are left `nil` unless explicit; `AshGrpc.Schema`
  # assigns them with the lock afterwards.

  alias AshGrpc.Domain.Info, as: DomainInfo
  alias AshGrpc.Domain.Service
  alias AshGrpc.Proto.{IR, WellKnown}
  alias AshGrpc.Resource.{Field, Rpc}
  alias AshGrpc.Resource.Info, as: ResourceInfo
  alias AshGrpc.Schema.{Naming, Types}
  alias Spark.Error.DslError

  # Import paths of non well-known types referenced by generated messages or common mappings.
  @known_imports %{
    "google.rpc.Status" => "google/rpc/status.proto",
    "google.type.Date" => "google/type/date.proto",
    "google.type.TimeOfDay" => "google/type/timeofday.proto",
    "google.type.Decimal" => "google/type/decimal.proto",
    "google.type.Money" => "google/type/money.proto",
    "google.type.LatLng" => "google/type/latlng.proto",
    "google.type.Interval" => "google/type/interval.proto"
  }

  @field_mask "google.protobuf.FieldMask"
  @empty "google.protobuf.Empty"

  @spec files([module()]) :: {:ok, [IR.File.t()]} | {:error, [Exception.t()]}
  def files(domains) do
    with :ok <- check_domains(domains) do
      registry = registry(domains)
      state = %{errors: [], defined: MapSet.new(), imports: [], extras: []}
      {files, state} = Enum.map_reduce(domains, state, &file(&1, registry, &2))

      case Enum.reverse(state.errors) ++ duplicate_errors(files) do
        [] -> {:ok, put_imports(files)}
        errors -> {:error, errors}
      end
    end
  end

  defp check_domains(domains) do
    errors =
      for domain <- domains, !DomainInfo.grpc?(domain) do
        DslError.exception(
          module: domain,
          path: [:grpc],
          message: "#{inspect(domain)} is not an Ash domain using the AshGrpc.Domain extension"
        )
      end

    if errors == [], do: :ok, else: {:error, errors}
  end

  ## Registry: resource => where its message lives

  defp registry(domains) do
    registry =
      for domain <- domains, resource <- DomainInfo.resources(domain), into: %{} do
        {resource, entry(resource, domain, :resource)}
      end

    domains
    |> Enum.flat_map(fn domain -> Enum.map(DomainInfo.resources(domain), &{&1, domain}) end)
    |> discover_embedded(registry)
  end

  defp entry(resource, domain, kind) do
    package = DomainInfo.package(domain)
    name = ResourceInfo.message_name(resource)

    %{
      name: name,
      full_name: IR.full_name(package, name),
      domain: domain,
      kind: kind,
      order: System.unique_integer([:monotonic])
    }
  end

  # Embedded resources get their message in the file of the first domain that references them.
  defp discover_embedded([], registry), do: registry

  defp discover_embedded([{resource, domain} | rest], registry) do
    found =
      resource
      |> referenced_types()
      |> Enum.flat_map(fn {type, constraints} -> resources_in_type(type, constraints) end)
      |> Enum.uniq()
      |> Enum.filter(&(Ash.Resource.Info.embedded?(&1) and not Map.has_key?(registry, &1)))

    registry = Enum.reduce(found, registry, &Map.put(&2, &1, entry(&1, domain, :embedded)))
    discover_embedded(rest ++ Enum.map(found, &{&1, domain}), registry)
  end

  defp referenced_types(resource) do
    fields =
      for field <- ResourceInfo.fields(resource), field.kind != :relationship do
        {field.type, field.constraints}
      end

    actions =
      for rpc <- ResourceInfo.rpcs(resource),
          action = Ash.Resource.Info.action(resource, rpc.action),
          type <- action_types(resource, action),
          do: type

    fields ++ actions
  end

  defp action_types(resource, action) do
    arguments = Enum.map(action.arguments, &{&1.type, &1.constraints})

    accepted =
      for name <- Map.get(action, :accept) || [],
          attribute = Ash.Resource.Info.attribute(resource, name),
          do: {attribute.type, attribute.constraints}

    returns =
      if action.type == :action and action.returns,
        do: [{action.returns, action.constraints}],
        else: []

    arguments ++ accepted ++ returns
  end

  defp resources_in_type({:array, inner}, constraints),
    do: resources_in_type(inner, Keyword.get(constraints || [], :items, []))

  defp resources_in_type(type, constraints) do
    constraints = constraints || []

    case Types.resource_type(type, constraints) do
      {resource, _} -> [resource]
      nil -> nested_resources(Ash.Type.get_type(type), constraints)
    end
  end

  defp nested_resources(type, constraints) do
    cond do
      is_atom(type) and Ash.Type.NewType.new_type?(type) ->
        resources_in_type(
          Ash.Type.NewType.subtype_of(type),
          Ash.Type.NewType.constraints(type, constraints)
        )

      # unions (`types`) and typed maps/structs/keywords/tuples (`fields`)
      entries =
          keyword_constraint(constraints, :types) || keyword_constraint(constraints, :fields) ->
        nested_resources(entries)

      true ->
        []
    end
  end

  defp keyword_constraint(constraints, key) do
    case constraints[key] do
      [_ | _] = entries -> if Keyword.keyword?(entries), do: entries
      _ -> nil
    end
  end

  defp nested_resources(entries) do
    Enum.flat_map(entries, fn {_name, config} ->
      if config[:type], do: resources_in_type(config[:type], config[:constraints] || []), else: []
    end)
  end

  ## Files

  defp file(domain, registry, state) do
    package = DomainInfo.package(domain)
    prefix = DomainInfo.module_prefix(domain)

    ctx = %{
      domain: domain,
      package: package,
      prefix: prefix,
      registry: registry,
      resolve: fn resource -> registry[resource] && registry[resource].full_name end
    }

    state = %{state | imports: [], extras: []}
    resources = DomainInfo.resources(domain)

    embedded =
      registry
      |> Enum.filter(fn {_, entry} -> entry.domain == domain and entry.kind == :embedded end)
      |> Enum.sort_by(fn {_, entry} -> entry.order end)
      |> Enum.map(&elem(&1, 0))

    {records, state} = Enum.map_reduce(resources ++ embedded, state, &record_message(&1, ctx, &2))

    {rpcs, state} =
      resources
      |> Enum.flat_map(fn resource -> Enum.map(ResourceInfo.rpcs(resource), &{resource, &1}) end)
      |> Enum.map_reduce(state, fn {resource, rpc}, state ->
        build_rpc(resource, rpc, ctx, state)
      end)

    extras = Enum.reverse(state.extras)

    file = %IR.File{
      path: DomainInfo.file(domain),
      package: package,
      doc: Spark.Dsl.Extension.get_opt(domain, [:grpc], :doc, nil),
      source: {:domain, domain},
      imports: state.imports ++ Spark.Dsl.Extension.get_opt(domain, [:grpc], :imports, []),
      options: to_options(DomainInfo.options(domain)),
      messages:
        Enum.map(
          records ++
            Enum.flat_map(rpcs, &elem(&1, 2)) ++ Enum.filter(extras, &is_struct(&1, IR.Message)),
          &put_module(&1, package, prefix)
        ),
      enums:
        extras
        |> Enum.filter(&is_struct(&1, IR.Enum))
        |> Enum.map(&put_module(&1, package, prefix)),
      services: services(domain, rpcs, ctx)
    }

    {file, state}
  end

  defp services(domain, rpcs, ctx) do
    declared = DomainInfo.services(domain)

    names =
      Enum.uniq(
        Enum.map(declared, & &1.name) ++ Enum.map(rpcs, fn {service, _, _} -> service end)
      )

    for name <- names,
        service_rpcs = for({^name, rpc, _} <- rpcs, do: rpc),
        service_rpcs != [] do
      config = Enum.find(declared, %Service{name: name}, &(&1.name == name))

      %IR.Service{
        name: name,
        full_name: IR.full_name(ctx.package, name),
        module: Module.concat(ctx.prefix, name <> ".Service"),
        doc: config.doc,
        source: {:domain, domain},
        rpcs: service_rpcs,
        options: to_options(config.options)
      }
    end
  end

  ## Record messages

  defp record_message(resource, ctx, state) do
    entry = ctx.registry[resource]

    {fields, state} =
      Enum.map_reduce(
        ResourceInfo.fields(resource),
        state,
        &record_field(resource, entry, &1, ctx, &2)
      )

    message = %IR.Message{
      name: entry.name,
      full_name: entry.full_name,
      doc: grpc_opt(resource, :doc) || Ash.Resource.Info.description(resource),
      source: {entry.kind, resource},
      fields: Enum.reject(fields, &is_nil/1),
      reserved_numbers: ResourceInfo.reserved_numbers(resource),
      reserved_names: ResourceInfo.reserved_names(resource),
      options: to_options(grpc_opt(resource, :options) || [])
    }

    {message, state}
  end

  defp record_field(resource, _entry, %{kind: :relationship} = field, ctx, state) do
    case ctx.registry[field.type] do
      nil ->
        {nil,
         add_error(
           state,
           resource,
           [:grpc, :fields, field.name],
           "relationship #{inspect(field.name)} points to #{inspect(field.type)}, which is not part " <>
             "of the schema (its domain must use AshGrpc.Domain and be passed to AshGrpc.Schema.build/2)"
         )}

      destination ->
        config = field.config || %Field{}

        ir = %IR.Field{
          name: field.proto_name,
          number: config.number,
          type: {:message, destination.full_name},
          label: if(field.cardinality == :many, do: :repeated),
          doc: config.doc || field.description,
          source: {:relationship, resource, field.name},
          deprecated?: config.deprecated?,
          json_name: config.json_name,
          options: to_options(config.options)
        }

        {ir, state}
    end
  end

  defp record_field(resource, entry, field, ctx, state) do
    config = field.config || %Field{}

    spec = %{
      resource: resource,
      name: field.proto_name,
      type: field.type,
      constraints: field.constraints,
      allow_nil?: field.allow_nil?,
      hint: entry.name <> Macro.camelize(field.proto_name),
      source: {field.kind, resource, field.name},
      path: [:grpc, :fields, field.name],
      doc: config.doc || field.description,
      number: config.number,
      representation: config.representation,
      deprecated?: config.deprecated?,
      json_name: config.json_name,
      options: config.options
    }

    typed_field(spec, ctx, state)
  end

  defp typed_field(spec, ctx, state) do
    opts = [
      allow_nil?: spec.allow_nil?,
      package: ctx.package,
      name_hint: spec.hint,
      representation: spec[:representation],
      resolve_resource: ctx.resolve
    ]

    case Types.map(spec.type, spec.constraints || [], opts) do
      {:ok, result} ->
        field = %IR.Field{
          name: spec.name,
          number: spec[:number],
          type: result.type,
          label: result.label,
          doc: spec[:doc],
          source: spec.source,
          deprecated?: spec[:deprecated?] || false,
          json_name: spec[:json_name],
          options: to_options(spec[:options] || [])
        }

        {field, add_result(state, result)}

      {:error, reason} ->
        {nil,
         add_error(
           state,
           spec.resource,
           spec.path,
           "#{spec.name}: #{Types.format_error(reason)}"
         )}
    end
  end

  defp add_result(state, result) do
    state = %{state | imports: state.imports ++ result.imports}

    Enum.reduce(result.messages ++ result.enums, state, fn item, state ->
      if MapSet.member?(state.defined, item.full_name) do
        state
      else
        %{
          state
          | extras: [item | state.extras],
            defined: MapSet.put(state.defined, item.full_name)
        }
      end
    end)
  end

  ## Rpcs

  defp build_rpc(resource, rpc, ctx, state) do
    action = Ash.Resource.Info.action(resource, rpc.action)
    rpc_name = Naming.rpc_name(rpc.name)
    shape = shape(rpc, action)
    rpc_ctx = Map.merge(ctx, %{resource: resource, rpc: rpc, action: action, rpc_name: rpc_name})

    {input, input_messages, state} = request(shape, rpc_ctx, state)
    {output, output_messages, state} = response(shape, rpc_ctx, state)

    ir = %IR.Rpc{
      name: rpc_name,
      input: input,
      output: output,
      doc: rpc.doc || action.description,
      source: {:action, resource, action.name, rpc},
      client_streaming?: rpc.kind in [:client_stream, :bidi_stream],
      server_streaming?: rpc.kind in [:server_stream, :bidi_stream],
      idempotency_level: idempotency_level(rpc, action),
      deprecated?: rpc.deprecated?,
      options: to_options(rpc.options)
    }

    service = DomainInfo.service_name(ctx.domain, resource, rpc)
    {{service, ir, input_messages ++ output_messages}, state}
  end

  # `:bidi_stream` rpcs reuse the shapes of the action type.
  defp shape(%Rpc{kind: :bidi_stream}, %{type: :read}), do: :server_stream
  defp shape(%Rpc{kind: :bidi_stream}, %{type: type}), do: type
  defp shape(%Rpc{kind: kind}, _action), do: kind

  defp idempotency_level(%Rpc{idempotency_level: :unknown}, _action), do: nil

  defp idempotency_level(%Rpc{idempotency_level: level}, _action) when not is_nil(level),
    do: level

  defp idempotency_level(_rpc, %{type: :read}), do: :no_side_effects
  defp idempotency_level(_rpc, _action), do: nil

  defp request(shape, ctx, state) do
    case ctx.rpc.request_message do
      module when is_atom(module) and not is_nil(module) ->
        {module.full_name(), [], state}

      name ->
        {fields, state} = request_fields(shape, ctx, state)

        generated(
          name || ctx.rpc_name <> "Request",
          {:action_input, ctx.resource, ctx.action.name},
          fields,
          ctx,
          state
        )
    end
  end

  defp generated(name, source, fields, ctx, state) do
    full_name = IR.full_name(ctx.package, name)
    fields = Enum.reject(fields, &is_nil/1)

    state =
      fields
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_, fields} -> length(fields) > 1 end)
      |> Enum.reduce(state, fn {field_name, _}, state ->
        add_error(
          state,
          ctx.resource,
          [:grpc, :rpc, ctx.rpc.name],
          "message #{full_name} has more than one field named #{inspect(field_name)}; " <>
            "rename the argument or use `proto_name:`"
        )
      end)

    message = %IR.Message{name: name, full_name: full_name, source: source, fields: fields}
    {full_name, [message], state}
  end

  defp request_fields(:get, ctx, state) do
    {by, state} =
      Enum.map_reduce(ctx.rpc.get_by, state, fn name, state ->
        case Enum.find(ctx.action.arguments, &(&1.name == name)) do
          nil ->
            attribute_field(Ash.Resource.Info.attribute(ctx.resource, name), true, ctx, state)

          argument ->
            argument_field(argument, true, ctx, state)
        end
      end)

    {args, state} = argument_fields(ctx, state, ctx.rpc.get_by)
    {by ++ args ++ read_mask(ctx), state}
  end

  defp request_fields(:list, ctx, state) do
    {args, state} = argument_fields(ctx, state)

    paging = [special(:page_size, :int32), special(:page_token, :string)]

    filter =
      if ctx.rpc.filter?, do: [special(:filter, :string), special(:order_by, :string)], else: []

    {args ++ paging ++ filter ++ read_mask(ctx), state}
  end

  defp request_fields(:server_stream, ctx, state) do
    {args, state} = argument_fields(ctx, state)
    {args ++ read_mask(ctx), state}
  end

  defp request_fields(kind, ctx, state) when kind in [:create, :client_stream, :update] do
    {input, state} = input_fields(kind, ctx, state)
    {args, state} = argument_fields(ctx, state)

    mask =
      if ctx.rpc.update_mask?,
        do: [special(:update_mask, {:message, @field_mask})],
        else: []

    {input ++ args ++ mask, state}
  end

  defp request_fields(:destroy, ctx, state) do
    {pk, state} = primary_key_fields(ctx, state)
    {args, state} = argument_fields(ctx, state)
    {pk ++ args, state}
  end

  defp request_fields(:action, ctx, state), do: argument_fields(ctx, state)

  defp input_fields(_kind, %{rpc: %Rpc{input: :wrapped}} = ctx, state) do
    record = ctx.registry[ctx.resource]

    field = %IR.Field{
      name: Naming.snake(record.name),
      type: {:message, record.full_name},
      source: {:special, :record}
    }

    {[field], state}
  end

  defp input_fields(kind, ctx, state) do
    {pk, state} = if kind == :update, do: primary_key_fields(ctx, state), else: {[], state}
    pk_names = Ash.Resource.Info.primary_key(ctx.resource)

    {accepted, state} =
      (ctx.action.accept || [])
      |> Enum.reject(&(kind == :update and &1 in pk_names))
      |> Enum.map(&Ash.Resource.Info.attribute(ctx.resource, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_reduce(state, fn attribute, state ->
        attribute_field(
          attribute,
          kind != :update and required?(attribute, ctx.action),
          ctx,
          state
        )
      end)

    {pk ++ accepted, state}
  end

  defp required?(attribute, action) do
    attribute.name in (Map.get(action, :require_attributes) || []) or
      (!attribute.allow_nil? and is_nil(attribute.default) and
         attribute.name not in (Map.get(action, :allow_nil_input) || []))
  end

  defp primary_key_fields(ctx, state) do
    ctx.resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.map(&Ash.Resource.Info.attribute(ctx.resource, &1))
    |> Enum.map_reduce(state, &attribute_field(&1, true, ctx, &2))
  end

  defp argument_fields(ctx, state, except \\ []) do
    ctx.action.arguments
    |> Enum.filter(&(Map.get(&1, :public?, true) and &1.name not in except))
    |> Enum.map_reduce(state, fn argument, state ->
      argument_field(argument, !argument.allow_nil? and is_nil(argument.default), ctx, state)
    end)
  end

  # Request fields for attributes reuse the record field's proto name and representation.
  defp attribute_field(attribute, required?, ctx, state) do
    config =
      ctx.resource |> ResourceInfo.field_configs() |> Enum.find(&(&1.name == attribute.name))

    name = (config && config.proto_name) || ResourceInfo.default_proto_name(attribute.name)

    typed_field(
      %{
        resource: ctx.resource,
        name: name,
        type: attribute.type,
        constraints: attribute.constraints,
        allow_nil?: !required?,
        hint: ctx.registry[ctx.resource].name <> Macro.camelize(name),
        source: {:attribute, ctx.resource, attribute.name},
        path: [:grpc, :rpc, ctx.rpc.name],
        doc: attribute.description,
        representation: config && config.representation
      },
      ctx,
      state
    )
  end

  defp argument_field(argument, required?, ctx, state) do
    name = ResourceInfo.default_proto_name(argument.name)

    typed_field(
      %{
        resource: ctx.resource,
        name: name,
        type: argument.type,
        constraints: argument.constraints,
        allow_nil?: !required?,
        hint: ctx.rpc_name <> Macro.camelize(name),
        source: {:argument, ctx.resource, ctx.action.name, argument.name},
        path: [:grpc, :rpc, ctx.rpc.name],
        doc: argument.description
      },
      ctx,
      state
    )
  end

  defp read_mask(%{rpc: %Rpc{read_mask?: true}}),
    do: [special(:read_mask, {:message, @field_mask})]

  defp read_mask(_ctx), do: []

  defp special(name, type, label \\ nil),
    do: %IR.Field{name: Atom.to_string(name), type: type, label: label, source: {:special, name}}

  defp response(shape, ctx, state) do
    case ctx.rpc.response_message do
      module when is_atom(module) and not is_nil(module) -> {module.full_name(), [], state}
      name -> default_response(shape, name, ctx, state)
    end
  end

  defp default_response(:list, name, ctx, state) do
    record = ctx.registry[ctx.resource]

    items =
      to_string(
        Ash.Resource.Info.plural_name(ctx.resource) || Naming.pluralize(Naming.snake(record.name))
      )

    fields = [
      %IR.Field{
        name: items,
        type: {:message, record.full_name},
        label: :repeated,
        source: {:special, :items}
      },
      special(:next_page_token, :string),
      special(:total_size, :int64, :optional)
    ]

    output(name, fields, ctx, state)
  end

  defp default_response(:client_stream, name, ctx, state) do
    fields = [
      special(:count, :int64),
      special(:errors, {:message, "google.rpc.Status"}, :repeated)
    ]

    output(name, fields, ctx, state)
  end

  defp default_response(:action, name, %{action: %{returns: nil}} = ctx, state),
    do: existing(@empty, name, ctx, state)

  defp default_response(:action, name, ctx, state) do
    action = ctx.action

    spec = %{
      resource: ctx.resource,
      name: "value",
      type: action.returns,
      constraints: action.constraints,
      allow_nil?: action.allow_nil?,
      hint: ctx.rpc_name <> "Result",
      source: {:special, :value},
      path: [:grpc, :rpc, ctx.rpc.name]
    }

    case typed_field(spec, ctx, state) do
      {nil, state} ->
        {@empty, [], state}

      {%IR.Field{type: {:message, full_name}, label: label}, state} when label != :repeated ->
        existing(full_name, name, ctx, state)

      {field, state} ->
        output(name, [field], ctx, state)
    end
  end

  defp default_response(:destroy, name, %{rpc: %Rpc{return_destroyed?: false}} = ctx, state),
    do: existing(@empty, name, ctx, state)

  defp default_response(_shape, name, ctx, state),
    do: existing(ctx.registry[ctx.resource].full_name, name, ctx, state)

  defp output(name, fields, ctx, state) do
    generated(
      name || ctx.rpc_name <> "Response",
      {:action_output, ctx.resource, ctx.action.name},
      fields,
      ctx,
      state
    )
  end

  defp existing(full_name, nil, _ctx, state), do: {full_name, [], state}

  defp existing(full_name, name, ctx, state) do
    {full_name, [],
     add_error(
       state,
       ctx.resource,
       [:grpc, :rpc, ctx.rpc.name],
       "`response_message: #{inspect(name)}` cannot rename the response: this rpc returns #{full_name}. " <>
         "Pass a protobuf module to replace it instead"
     )}
  end

  ## Post-processing

  defp put_module(%{module: nil, full_name: full_name} = item, package, prefix) do
    module =
      if package && String.starts_with?(full_name, package <> ".") do
        Module.concat([prefix, String.replace_prefix(full_name, package <> ".", "")])
      else
        full_name |> String.split(".") |> Enum.map(&Macro.camelize/1) |> Module.concat()
      end

    put_nested_modules(%{item | module: module})
  end

  defp put_module(item, _package, _prefix), do: put_nested_modules(item)

  defp put_nested_modules(%IR.Message{} = message) do
    put = fn nested ->
      %{nested | module: nested.module || Module.concat(message.module, nested.name)}
    end

    %{
      message
      | nested_messages: Enum.map(message.nested_messages, &put_nested_modules(put.(&1))),
        nested_enums: Enum.map(message.nested_enums, put)
    }
  end

  defp put_nested_modules(item), do: item

  defp duplicate_errors(files) do
    types =
      for file <- files, item <- file.messages ++ file.enums ++ file.services do
        {item.full_name, {file.path, item.source}}
      end

    types
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_, sources} -> length(sources) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {full_name, sources} ->
      DslError.exception(
        path: [:grpc],
        message:
          "#{full_name} is defined more than once: " <>
            Enum.map_join(sources, "; ", fn {path, source} -> "#{inspect(source)} in #{path}" end)
      )
    end)
  end

  defp put_imports(files) do
    defined_in =
      for file <- files, item <- all_types(file.messages, file.enums), into: %{} do
        {item.full_name, file.path}
      end

    Enum.map(files, fn file ->
      own = MapSet.new(all_types(file.messages, file.enums), & &1.full_name)

      computed =
        for ref <- references(file), !MapSet.member?(own, ref) do
          WellKnown.import_path(ref) || defined_in[ref] || @known_imports[ref]
        end

      imports =
        (file.imports ++ computed)
        |> Enum.reject(&(is_nil(&1) or &1 == file.path))
        |> Enum.uniq()
        |> Enum.sort()

      %{file | imports: imports}
    end)
  end

  defp all_types(messages, enums) do
    enums ++
      Enum.flat_map(messages, fn message ->
        [message | all_types(message.nested_messages, message.nested_enums)]
      end)
  end

  defp references(file) do
    fields =
      for message <- all_types(file.messages, []),
          field <- message.fields,
          ref <- type_refs(field.type),
          do: ref

    rpcs =
      for service <- file.services, rpc <- service.rpcs, ref <- [rpc.input, rpc.output], do: ref

    Enum.uniq(fields ++ rpcs)
  end

  defp type_refs({:message, name}), do: [name]
  defp type_refs({:enum, name}), do: [name]
  defp type_refs({:map, _key, value}), do: type_refs(value)
  defp type_refs(_scalar), do: []

  ## Helpers

  defp grpc_opt(resource, option), do: Spark.Dsl.Extension.get_opt(resource, [:grpc], option, nil)

  defp to_options(options) do
    Enum.map(options, fn {name, value} -> %IR.Option{name: to_string(name), value: value} end)
  end

  defp add_error(state, module, path, message) do
    error = DslError.exception(module: module, path: path, message: message)
    %{state | errors: [error | state.errors]}
  end
end
