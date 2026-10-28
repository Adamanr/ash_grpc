defmodule AshGrpc.Server do
  @moduledoc """
  Runs an `AshGrpc.Endpoint` (supervised `GRPC.Server.Supervisor`, plus the health and
  reflection processes the endpoint needs).

      # application.ex
      children = [
        {AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 50051}
      ]

  ## Options

    * `:endpoint` – the `AshGrpc.Endpoint` module (required)
    * `:port` – TCP port (default `50051`; `0` picks a free port, see `port/1`)
    * `:start_server` – start listening (default `true`); `false` only starts the support
      processes, e.g. in tests that do not need a socket
    * `:cred` – a `GRPC.Credential` (TLS); `:tls` – SSL options, shorthand for
      `cred: GRPC.Credential.new(ssl: tls)`
    * `:ip` – interface to bind to, e.g. `{0, 0, 0, 0}`
    * `:adapter_opts` – extra options for the cowboy adapter (`:num_acceptors`,
      `:max_connections`, `:idle_timeout`, ...)
    * `:max_message_size` – max request size in bytes (defaults to the endpoint's
      `max_message_size`, otherwise 4 MiB)
    * `:exception_log_filter` – `{module, function}` deciding which handler exceptions are
      logged by `grpc_server`
    * `:name` – supervisor name (default `Module.concat(endpoint, Supervisor)`)

  ## Request context

  Interceptors store the actor, tenant and extra Ash context of a request in the
  `GRPC.Server.Stream` with `put_actor/2`, `put_tenant/2` and `put_context/2`; the generated
  handlers pass them to every Ash call.
  """

  use Supervisor

  @default_port 50_051

  @doc "Child spec, see the module docs for options."
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)

    %{
      id: {__MODULE__, endpoint},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts the server supervisor, see the module docs for options."
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    name = Keyword.get(opts, :name, Module.concat(endpoint, Supervisor))
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)

    unless Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :__ash_grpc__, 1) do
      raise ArgumentError, "#{inspect(endpoint)} is not an AshGrpc.Endpoint"
    end

    config = endpoint.__ash_grpc__(:config)

    health =
      if config.health?, do: [{AshGrpc.Server.Health, endpoint: endpoint}], else: []

    reflection =
      if config.reflection != [], do: [AshGrpc.Server.Reflection.child_spec([])], else: []

    Supervisor.init(health ++ reflection ++ [grpc_supervisor(endpoint, config, opts)],
      strategy: :rest_for_one
    )
  end

  defp grpc_supervisor(endpoint, config, opts) do
    adapter_opts =
      opts
      |> Keyword.get(:adapter_opts, [])
      |> put_new(:cred, cred(opts))
      |> put_new(:ip, opts[:ip])

    grpc_opts =
      [
        endpoint: endpoint,
        port: Keyword.get(opts, :port, @default_port),
        start_server: Keyword.get(opts, :start_server, true),
        adapter_opts: adapter_opts
      ]
      |> put_new(:max_body_size, opts[:max_message_size] || config.max_message_size)
      |> put_new(:exception_log_filter, opts[:exception_log_filter])

    {GRPC.Server.Supervisor, grpc_opts}
  end

  defp cred(opts) do
    cond do
      opts[:cred] -> opts[:cred]
      opts[:tls] -> GRPC.Credential.new(ssl: opts[:tls])
      true -> nil
    end
  end

  defp put_new(opts, _key, nil), do: opts
  defp put_new(opts, key, value), do: Keyword.put_new(opts, key, value)

  @doc """
  The port a running endpoint listens on (useful with `port: 0`), or `nil` when it is not
  running.
  """
  @spec port(module()) :: :inet.port_number() | nil
  def port(endpoint) do
    :ranch.get_port(inspect(endpoint))
  catch
    _, _ -> nil
  end

  ## Request context helpers (for interceptors)

  @doc "Stores the Ash actor for the request handled with `stream`."
  @spec put_actor(GRPC.Server.Stream.t(), term()) :: GRPC.Server.Stream.t()
  def put_actor(stream, actor), do: put_local(stream, :actor, actor)

  @doc "The actor stored with `put_actor/2` (or `nil`)."
  @spec actor(GRPC.Server.Stream.t()) :: term()
  def actor(stream), do: get_local(stream, :actor)

  @doc "Stores the Ash tenant for the request handled with `stream`."
  @spec put_tenant(GRPC.Server.Stream.t(), term()) :: GRPC.Server.Stream.t()
  def put_tenant(stream, tenant), do: put_local(stream, :tenant, tenant)

  @doc "The tenant stored with `put_tenant/2` (or `nil`)."
  @spec tenant(GRPC.Server.Stream.t()) :: term()
  def tenant(stream), do: get_local(stream, :tenant)

  @doc "Merges `context` into the Ash context passed to every Ash call of the request."
  @spec put_context(GRPC.Server.Stream.t(), map()) :: GRPC.Server.Stream.t()
  def put_context(stream, context) when is_map(context),
    do: put_local(stream, :context, Map.merge(context(stream), context))

  @doc "The Ash context stored with `put_context/2`."
  @spec context(GRPC.Server.Stream.t()) :: map()
  def context(stream), do: get_local(stream, :context) || %{}

  defp put_local(%{local: local} = stream, key, value) do
    local = if is_map(local), do: local, else: %{}
    ash_grpc = local |> Map.get(:ash_grpc, %{}) |> Map.put(key, value)
    %{stream | local: Map.put(local, :ash_grpc, ash_grpc)}
  end

  defp get_local(%{local: %{ash_grpc: values}}, key), do: Map.get(values, key)
  defp get_local(_stream, _key), do: nil
end
