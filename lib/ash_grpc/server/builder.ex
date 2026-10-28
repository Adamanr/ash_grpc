defmodule AshGrpc.Server.Builder do
  @moduledoc false
  # Compile-time code generation for `use AshGrpc.Endpoint`.

  alias AshGrpc.Proto.{Compiler, IR, Lock}

  @options [
    :otp_app,
    :domains,
    interceptors: [],
    servers: [],
    reflection: false,
    health: true,
    lock_path: nil,
    require_lock?: nil,
    show_raised_errors?: nil,
    max_message_size: nil,
    compressors: [GRPC.Compressor.Gzip],
    default_page_size: nil,
    max_page_size: nil,
    stream_batch_size: 100
  ]

  @doc false
  def options, do: @options

  @doc "Quoted body of an endpoint module."
  @spec endpoint(Keyword.t(), Macro.Env.t()) :: Macro.t()
  def endpoint(opts, caller) do
    {opts, _} = Code.eval_quoted(opts, [], caller)
    opts = Keyword.validate!(opts, @options)
    endpoint = caller.module

    {otp_app, domains} = required_options!(opts, caller)
    ensure_compiled!(domains)
    lock_path = opts[:lock_path] || Lock.default_path(otp_app)
    schema = build_schema!(domains, lock_path, opts, caller)

    services = for file <- schema.files, service <- file.services, do: service
    servers = Enum.map(services, &{&1, Module.concat([endpoint, Servers, &1.name])})
    health? = opts[:health] == true
    reflection = reflection_modules(endpoint, opts[:reflection], caller)
    health_service = if health?, do: [AshGrpc.Server.Health.service()], else: []
    service_modules = Enum.map(services, & &1.module) ++ health_service

    config =
      opts
      |> Keyword.take([
        :max_message_size,
        :show_raised_errors?,
        :default_page_size,
        :max_page_size,
        :stream_batch_size
      ])
      |> Map.new()
      |> Map.merge(%{
        otp_app: otp_app,
        domains: domains,
        lock_path: lock_path,
        health?: health?,
        reflection: Enum.map(reflection, &elem(&1, 0)),
        services: Enum.map(services, & &1.full_name)
      })

    health_server = if health?, do: [AshGrpc.Server.Health.Server], else: []

    run =
      Enum.map(servers, &elem(&1, 1)) ++
        health_server ++ Enum.map(reflection, &elem(&1, 0)) ++ List.wrap(opts[:servers])

    quote do
      @external_resource unquote(Path.expand(lock_path))

      # compile-time dependencies: changes to domains/resources recompile the endpoint
      unquote_splicing(Enum.map(dependencies(domains, schema), &quote(do: require(unquote(&1)))))

      unquote_splicing(Enum.map(Compiler.quoted(schema, compiler_opts()), &elem(&1, 1)))

      unquote_splicing(
        Enum.map(servers, fn {service, module} ->
          server_ast(endpoint, service, module, opts[:compressors])
        end)
      )

      unquote_splicing(
        Enum.map(reflection, fn {module, version} ->
          reflection_ast(module, version, service_modules)
        end)
      )

      use GRPC.Endpoint

      unquote_splicing(
        Enum.map(opts[:interceptors], fn
          {interceptor, interceptor_opts} ->
            quote do: intercept(unquote(interceptor), unquote(Macro.escape(interceptor_opts)))

          interceptor ->
            quote do: intercept(unquote(interceptor))
        end)
      )

      run(unquote(run))

      @doc "The `AshGrpc.Proto.IR.Schema` served by this endpoint."
      @spec schema() :: AshGrpc.Proto.IR.Schema.t()
      def schema, do: unquote(Macro.escape(schema))

      @doc false
      def __ash_grpc__(:config), do: unquote(Macro.escape(config))

      unquote_splicing(rpc_clauses(schema, services))

      def __ash_grpc__({:rpc, key}),
        do: raise(ArgumentError, "unknown rpc #{inspect(key)} in #{inspect(__MODULE__)}")
    end
  end

  defp required_options!(opts, caller) do
    otp_app = opts[:otp_app] || compile_error!(caller, "AshGrpc.Endpoint requires :otp_app")

    case List.wrap(opts[:domains]) do
      [] -> compile_error!(caller, "AshGrpc.Endpoint requires :domains")
      domains -> {otp_app, domains}
    end
  end

  # The schema is built while this macro expands, so the domains and their resources must be
  # compiled first: in a project the endpoint is usually compiled in parallel with them, and a
  # module that is still being compiled is not loaded yet.
  defp ensure_compiled!(domains) do
    for domain <- domains, match?({:module, _}, Code.ensure_compiled(domain)) do
      if function_exported?(domain, :spark_dsl_config, 0) do
        domain |> Ash.Domain.Info.resources() |> Enum.each(&Code.ensure_compiled!/1)
      end
    end

    :ok
  end

  ## Schema and lock

  defp build_schema!(domains, lock_path, opts, caller) do
    lock =
      case Lock.load(lock_path) do
        {:ok, lock} -> lock
        {:error, error} -> compile_error!(caller, "cannot load #{lock_path}: #{inspect(error)}")
      end

    case AshGrpc.Schema.build_with_lock(domains, lock: lock) do
      {:ok, schema, new_lock} ->
        if Lock.encode(new_lock) != Lock.encode(lock), do: stale_lock(lock_path, opts, caller)
        schema

      {:error, errors} ->
        compile_error!(
          caller,
          "cannot build the gRPC schema:\n" <> Enum.map_join(errors, "\n", &Exception.message/1)
        )
    end
  end

  defp stale_lock(lock_path, opts, caller) do
    message =
      "#{inspect(caller.module)}: the proto lock #{lock_path} is missing or out of date, " <>
        "field numbers are provisional. Run `mix ash_grpc.codegen` to update it."

    require? =
      case opts[:require_lock?] do
        nil -> Application.get_env(:ash_grpc, :require_lock?, false)
        value -> value
      end

    if require?, do: compile_error!(caller, message), else: IO.warn(message, caller)
  end

  # domains, their resources and every resource/embedded resource with a message
  defp dependencies(domains, schema) do
    resources =
      for file <- schema.files,
          %IR.Message{source: {kind, resource}} <- file.messages,
          kind in [:resource, :embedded],
          do: resource

    Enum.uniq(domains ++ Enum.flat_map(domains, &AshGrpc.Domain.Info.resources/1) ++ resources)
  end

  ## Servers

  defp server_ast(endpoint, service, module, compressors) do
    functions =
      Enum.map(service.rpcs, fn rpc ->
        name = rpc.name |> Macro.underscore() |> String.to_atom()
        key = {service.full_name, rpc.name}

        quote do
          @doc false
          def unquote(name)(request, stream),
            do: AshGrpc.Server.Handler.handle(unquote(endpoint), unquote(key), request, stream)
        end
      end)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use GRPC.Server, service: unquote(service.module), compressors: unquote(compressors)

        unquote_splicing(functions)
      end
    end
  end

  defp rpc_clauses(schema, services) do
    for service <- services, rpc <- service.rpcs do
      {:action, resource, action, config} = rpc.source
      {:domain, domain} = service.source

      info = %{
        service: service.full_name,
        rpc: rpc,
        input: message(schema, rpc.input),
        output: message(schema, rpc.output),
        input_module: module(schema, rpc.input, config.request_message),
        output_module: module(schema, rpc.output, config.response_message),
        record: record_message(schema, resource),
        resource: resource,
        action: action,
        domain: domain,
        config: config
      }

      quote do
        def __ash_grpc__({:rpc, unquote(Macro.escape({service.full_name, rpc.name}))}),
          do: unquote(Macro.escape(info))
      end
    end
  end

  defp message(schema, full_name) do
    case IR.Schema.lookup(schema, full_name) do
      {:ok, %IR.Message{} = message} -> message
      _ -> nil
    end
  end

  defp module(_schema, _full_name, module) when is_atom(module) and not is_nil(module), do: module
  defp module(schema, full_name, _), do: Compiler.module_for(schema, full_name, compiler_opts())

  defp compiler_opts, do: [modules: AshGrpc.Server.StatusProto.modules()]

  defp record_message(schema, resource) do
    schema.files
    |> Enum.flat_map(& &1.messages)
    |> Enum.find(&(&1.source == {:resource, resource}))
  end

  ## Reflection

  defp reflection_modules(_endpoint, false, _caller), do: []
  defp reflection_modules(_endpoint, nil, _caller), do: []

  defp reflection_modules(endpoint, reflection, caller) do
    unless Code.ensure_loaded?(GrpcReflection.Server) do
      compile_error!(caller, "reflection: true requires the optional :grpc_reflection dependency")
    end

    versions = if reflection == true, do: [:v1, :v1alpha], else: List.wrap(reflection)

    Enum.map(versions, fn
      :v1 -> {Module.concat([endpoint, Reflection, V1]), :v1}
      :v1alpha -> {Module.concat([endpoint, Reflection, V1alpha]), :v1alpha}
      other -> compile_error!(caller, "invalid reflection version #{inspect(other)}")
    end)
  end

  defp reflection_ast(module, version, services) do
    quote do
      defmodule unquote(module) do
        @moduledoc false
        use GrpcReflection.Server, version: unquote(version), services: unquote(services)
      end
    end
  end

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(caller, message) do
    raise CompileError, file: caller.file, line: caller.line, description: message
  end
end
