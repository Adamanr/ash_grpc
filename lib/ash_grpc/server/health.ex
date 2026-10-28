require AshGrpc.Server.Builder.Protos
AshGrpc.Server.Builder.Protos.define(AshGrpc.Server.StatusProto.schema())
AshGrpc.Server.Builder.Protos.define(AshGrpc.Server.Health.Proto.schema())

defmodule AshGrpc.Server.Health do
  @moduledoc """
  The standard gRPC health service (`grpc.health.v1.Health`: `Check` and `Watch`), mounted by
  every `AshGrpc.Endpoint` unless `health: false`. Kubernetes gRPC probes, `grpc_health_probe`,
  Envoy and load balancers use it.

  Statuses are kept per endpoint and service name (`""` is the whole server). While the
  endpoint runs under `AshGrpc.Server`, the server and every service of the endpoint are
  `:serving`; they become `:not_serving` when it shuts down. Unknown services are reported as
  `NOT_FOUND` by `Check` and `SERVICE_UNKNOWN` by `Watch`.

      AshGrpc.Server.Health.set_status(MyApp.GrpcEndpoint, "myapp.v1.AccountsService", :not_serving)

  The process is started by `AshGrpc.Server`.
  """

  use GenServer

  alias AshGrpc.Server.Health.V1.HealthCheckResponse

  @type status :: :serving | :not_serving | :unknown

  @doc "The `GRPC.Service` module of `grpc.health.v1.Health`."
  @spec service() :: module()
  def service, do: AshGrpc.Server.Health.Proto.service_module()

  @doc false
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    GenServer.start_link(__MODULE__, endpoint, name: name(endpoint))
  end

  @doc "Sets the status of `service` (`\"\"` = the whole server) of `endpoint`."
  @spec set_status(module(), String.t(), status()) :: :ok
  def set_status(endpoint, service \\ "", status)
      when status in [:serving, :not_serving, :unknown] do
    statuses = Map.put(statuses(endpoint), service, status)
    :persistent_term.put(key(endpoint), statuses)

    case GenServer.whereis(name(endpoint)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:changed, service, status})
    end
  end

  @doc """
  The status of `service` of `endpoint`, or `:service_unknown` for services the endpoint does
  not serve.
  """
  @spec status(module(), String.t()) :: status() | :service_unknown
  def status(endpoint, service \\ "") do
    case Map.fetch(statuses(endpoint), service) do
      {:ok, status} -> status
      :error -> :service_unknown
    end
  end

  defp statuses(endpoint) do
    :persistent_term.get(key(endpoint), nil) || default_statuses(endpoint, :serving)
  end

  defp default_statuses(endpoint, status) do
    Map.new(["" | endpoint.__ash_grpc__(:config).services], &{&1, status})
  end

  defp key(endpoint), do: {__MODULE__, endpoint}
  defp name(endpoint), do: Module.concat(endpoint, Health)

  @doc false
  # Registers the calling process for status changes of `endpoint`
  # (`{:ash_grpc_health, service, status}` messages).
  @spec watch(module()) :: :ok
  def watch(endpoint) do
    case GenServer.whereis(name(endpoint)) do
      nil -> :ok
      pid -> GenServer.call(pid, {:watch, self()})
    end
  end

  @doc false
  @spec to_proto(status() | :service_unknown) :: atom()
  def to_proto(:serving), do: :SERVING
  def to_proto(:not_serving), do: :NOT_SERVING
  def to_proto(:service_unknown), do: :SERVICE_UNKNOWN
  def to_proto(_), do: :UNKNOWN

  ## GenServer

  @impl true
  def init(endpoint) do
    Process.flag(:trap_exit, true)
    :persistent_term.put(key(endpoint), default_statuses(endpoint, :serving))
    {:ok, %{endpoint: endpoint, watchers: %{}}}
  end

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, put_in(state.watchers[ref], pid)}
  end

  @impl true
  def handle_cast({:changed, service, status}, state) do
    for {_ref, pid} <- state.watchers, do: send(pid, {:ash_grpc_health, service, status})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | watchers: Map.delete(state.watchers, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    statuses = Map.new(statuses(state.endpoint), fn {service, _} -> {service, :not_serving} end)
    :persistent_term.put(key(state.endpoint), statuses)

    for {service, _} <- statuses,
        {_ref, pid} <- state.watchers,
        do: send(pid, {:ash_grpc_health, service, :not_serving})

    :ok
  end

  @doc false
  @spec response(module(), String.t()) :: struct()
  def response(endpoint, service),
    do: %HealthCheckResponse{status: to_proto(status(endpoint, service))}
end

defmodule AshGrpc.Server.Health.Server do
  @moduledoc """
  `GRPC.Server` implementing `grpc.health.v1.Health` for the endpoint handling the request
  (see `AshGrpc.Server.Health`).
  """

  use GRPC.Server, service: AshGrpc.Server.Health.V1.Health.Service

  alias AshGrpc.Server.Health

  @doc "`Check`: the status of the requested service; `NOT_FOUND` for unknown services."
  @spec check(struct(), GRPC.Server.Stream.t()) :: struct()
  def check(request, stream) do
    case Health.status(stream.endpoint, request.service) do
      :service_unknown ->
        raise GRPC.RPCError, status: GRPC.Status.not_found(), message: "unknown service"

      _status ->
        Health.response(stream.endpoint, request.service)
    end
  end

  @doc "`Watch`: sends the current status, then every change, until the client cancels."
  @spec watch(struct(), GRPC.Server.Stream.t()) :: GRPC.Server.Stream.t()
  def watch(request, stream) do
    :ok = Health.watch(stream.endpoint)
    response = Health.response(stream.endpoint, request.service)
    GRPC.Server.send_reply(stream, response)
    loop(request.service, response, stream)
  end

  defp loop(service, last, stream) do
    receive do
      {:ash_grpc_health, ^service, _status} ->
        case Health.response(stream.endpoint, service) do
          ^last ->
            loop(service, last, stream)

          response ->
            GRPC.Server.send_reply(stream, response)
            loop(service, response, stream)
        end
    end
  end
end
