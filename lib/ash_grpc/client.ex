defmodule AshGrpc.Client do
  @moduledoc """
  Repo-like clients for external gRPC services.

  Define one module per external service (or group of services sharing an address) and add it
  to your supervision tree:

      defmodule MyApp.Billing do
        use AshGrpc.Client, otp_app: :my_app, services: [Billing.V1.BillingService.Service]
      end

      # config/runtime.exs
      config :my_app, MyApp.Billing,
        address: "dns:///billing.internal:50051",
        tls: [cacertfile: "...", certfile: "...", keyfile: "..."],
        pool_size: 4,
        deadline: 5_000,
        retry: [max_attempts: 3, backoff: {:exponential, 50, 2_000}, on: [:unavailable]],
        idempotent: [:get_invoice],
        metadata: {MyApp.Billing.Auth, :metadata, []},
        compression: :gzip

      # application.ex
      children = [MyApp.Billing, MyApp.Search]

      MyApp.Billing.call(:charge, %{amount: 100}, deadline: 1_000, actor: actor)
      {:ok, invoices} = MyApp.Billing.stream(:watch_invoices, %{customer_id: "c1"})

  Every client has its own supervisor, connection pool and configuration, so an application
  can talk to any number of services at once. Clients can also be started dynamically, with
  configuration only known at runtime:

      {:ok, _pid} =
        AshGrpc.Client.start_link(
          name: :tenant_42_billing,
          services: [Billing.V1.BillingService.Service],
          address: "tenant-42.billing.internal:50051"
        )

      AshGrpc.Client.call(:tenant_42_billing, :charge, %{amount: 100})

  Configuration is documented in `AshGrpc.Client.Config`; call options, telemetry events and
  retries in `AshGrpc.Client.Call` and `AshGrpc.Client.Retry`; testing in
  `AshGrpc.Client.Sandbox`.

  ## Rpc names

  An rpc can be referenced by its proto name (`:GetUser`), its snake_case name (`:get_user`),
  either as a string, as `{ServiceModule, name}` or by full path
  (`"/pkg.v1.UserService/GetUser"`), see `AshGrpc.Client.RpcTable`.

  ## Return values

    * unary: `{:ok, response} | {:error, exception}`
    * server / bidirectional streaming: `{:ok, Enumerable.t()} | {:error, exception}`; the
      enumerable yields response structs and raises the mapped exception if the stream fails,
    * client streaming: `{:ok, response} | {:error, exception}`; pass an enumerable of
      requests (structs or maps).

  Errors returned by the server (and transport failures, normalized to `UNAVAILABLE`,
  `DEADLINE_EXCEEDED` …) are mapped through `AshGrpc.Client.Errors`. Programming errors such as
  an unknown rpc or invalid request fields are returned as `{:error, %ArgumentError{}}`.

  ## Runtime configuration (`init/1`)

  Like `Ecto.Repo`, a client module may define `c:init/1` to adjust its configuration when it
  starts:

      def init(config) do
        {:ok, Keyword.put(config, :address, System.fetch_env!("BILLING_ADDR"))}
      end
  """

  alias AshGrpc.Client.{Call, Config, Pool, Runtime}

  @typedoc "A client: a `use AshGrpc.Client` module or the name of a dynamic client."
  @type client :: atom()

  @typedoc "An rpc reference (see \"Rpc names\")."
  @type rpc :: atom() | String.t() | {module(), atom() | String.t()}

  @doc """
  Optional callback invoked when the client starts, with the merged configuration
  (use options, application env and start options). Returns the final configuration.
  """
  @callback init(config :: keyword()) :: {:ok, keyword()}

  @optional_callbacks init: 1

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour AshGrpc.Client

      @ash_grpc_client_opts opts
      @ash_grpc_services Keyword.get(opts, :services, [])

      for service <- @ash_grpc_services, do: Code.ensure_compiled!(service)

      @ash_grpc_rpc_table AshGrpc.Client.RpcTable.build(@ash_grpc_services)

      @doc false
      def __rpc_table__, do: @ash_grpc_rpc_table

      @doc false
      def __services__, do: @ash_grpc_services

      @doc false
      def __client_opts__, do: @ash_grpc_client_opts

      @doc "Child spec to start this client under a supervisor."
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts \\ []) do
        %{
          id: Keyword.get(opts, :name, __MODULE__),
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      @doc "Starts this client. `opts` override the configuration (see `AshGrpc.Client.Config`)."
      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(opts \\ []) do
        AshGrpc.Client.start_client(__MODULE__, @ash_grpc_client_opts, opts)
      end

      @doc "Calls a unary rpc. See `AshGrpc.Client`."
      @spec call(AshGrpc.Client.rpc(), struct() | map() | keyword(), keyword()) ::
              {:ok, struct()} | {:ok, struct(), map()} | {:error, Exception.t()}
      def call(rpc, request, opts \\ []), do: AshGrpc.Client.call(__MODULE__, rpc, request, opts)

      @doc "Calls a streaming rpc. See `AshGrpc.Client`."
      @spec stream(AshGrpc.Client.rpc(), term(), keyword()) ::
              {:ok, Enumerable.t()} | {:ok, struct()} | {:error, Exception.t()}
      def stream(rpc, request_or_enum, opts \\ []),
        do: AshGrpc.Client.stream(__MODULE__, rpc, request_or_enum, opts)

      @doc "Checks out a connected `GRPC.Channel` (e.g. to use generated stubs directly)."
      @spec channel(keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
      def channel(opts \\ []), do: AshGrpc.Client.channel(__MODULE__, opts)

      @doc "Health of this client's connections. See `AshGrpc.Client.health/1`."
      @spec health() :: map()
      def health, do: AshGrpc.Client.health(__MODULE__)

      @doc "The validated runtime configuration of this client."
      @spec config() :: AshGrpc.Client.Config.t()
      def config, do: AshGrpc.Client.config(__MODULE__)
    end
  end

  @doc """
  Starts a dynamically configured client. Requires `:name` and `:services` plus the
  connection options of `AshGrpc.Client.Config` (`:otp_app` is optional).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    start_client(nil, [], opts)
  end

  @doc "Child spec for a dynamically configured client (see `start_link/1`)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  @spec start_client(module() | nil, keyword(), keyword()) :: Supervisor.on_start()
  def start_client(module, use_opts, start_opts) do
    case Config.build(module, use_opts, start_opts) do
      {:ok, config} -> AshGrpc.Client.Supervisor.start_link(config)
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Calls the unary `rpc` of `client` with `request` (a request struct, map or keyword list).

  See `AshGrpc.Client.Call` for options.
  """
  @spec call(client(), rpc(), struct() | map() | keyword(), keyword()) ::
          {:ok, struct()} | {:ok, struct(), map()} | {:error, Exception.t()}
  def call(client, rpc, request, opts \\ []), do: Call.unary(client, rpc, request, opts)

  @doc """
  Calls a streaming `rpc` of `client`.

    * server streaming: `request` is one request, returns `{:ok, stream_of_responses}`,
    * client streaming: `request` is an enumerable of requests, returns `{:ok, response}`,
    * bidirectional: `request` is an enumerable of requests (sent from a linked process while
      responses are consumed), returns `{:ok, stream_of_responses}`.

  For interactive bidirectional streams use `channel/2` with the generated stub.
  """
  @spec stream(client(), rpc(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:ok, struct()} | {:error, Exception.t()}
  def stream(client, rpc, request_or_enum, opts \\ []),
    do: Call.stream(client, rpc, request_or_enum, opts)

  @doc """
  Checks out a connected `GRPC.Channel` of `client`, round-robin over its pool.

  Options: `:timeout` - how long to wait for a connection being established (defaults to
  the client's `:connect_timeout`).
  """
  @spec channel(client(), keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def channel(client, opts \\ []), do: Call.channel(client, opts)

  @doc """
  Health of `client`: `%{status: :ready | :connecting | :idle, connections: [...]}`, or
  `%{status: :sandbox}` for sandboxed clients and `%{status: :stopped}` when not running.
  """
  @spec health(client()) :: map()
  def health(client) do
    case Runtime.fetch(client) do
      {:ok, %{config: %{sandbox: true}}} -> %{status: :sandbox, connections: []}
      {:ok, runtime} -> Pool.health(runtime)
      {:error, _} -> %{status: :stopped, connections: []}
    end
  end

  @doc "The validated configuration of a running client."
  @spec config(client()) :: Config.t()
  def config(client) do
    case Runtime.fetch(client) do
      {:ok, runtime} -> runtime.config
      {:error, error} -> raise error
    end
  end

  @doc """
  Sets the deadline for client calls made by the current process, as milliseconds from now
  (or `nil` to clear it). Calls use the earlier of this deadline and their own.

  Meant for propagating an incoming request's deadline (e.g. by a server interceptor) to
  outgoing calls.
  """
  @spec put_deadline(non_neg_integer() | nil) :: :ok
  def put_deadline(nil) do
    Process.delete(Call.deadline_key())
    :ok
  end

  def put_deadline(ms) when is_integer(ms) and ms >= 0 do
    Process.put(Call.deadline_key(), System.monotonic_time(:millisecond) + ms)
    :ok
  end

  @doc "Remaining milliseconds of the deadline set with `put_deadline/1`, or `nil`."
  @spec remaining_deadline() :: integer() | nil
  def remaining_deadline do
    case Process.get(Call.deadline_key()) do
      nil -> nil
      at -> at - System.monotonic_time(:millisecond)
    end
  end
end
