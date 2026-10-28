defmodule AshGrpc.Client.Runtime do
  @moduledoc false
  # The per-client runtime state, stored in `:persistent_term` under `{AshGrpc.Client, name}` by
  # `AshGrpc.Client.Runtime.Keeper` (the first child of the client supervisor) for the lifetime
  # of the client. Calls read it without going through any process.

  alias AshGrpc.Client.{Config, RpcTable}

  @type t :: %__MODULE__{
          config: Config.t(),
          table: RpcTable.t(),
          idempotent: MapSet.t(),
          connections: tuple(),
          counter: :atomics.atomics_ref(),
          dynamic_supervisor: atom() | nil
        }

  defstruct [:config, :table, :idempotent, :connections, :counter, :dynamic_supervisor]

  @spec new(Config.t()) :: t()
  def new(%Config{} = config) do
    table =
      if config.module && function_exported?(config.module, :__rpc_table__, 0) &&
           config.services == config.module.__services__() do
        config.module.__rpc_table__()
      else
        RpcTable.build(config.services)
      end

    idempotent =
      config.idempotent
      |> Enum.flat_map(fn name ->
        case RpcTable.fetch(table, name) do
          {:ok, entry} ->
            [entry.path]

          {:error, error} ->
            raise ArgumentError,
                  "invalid :idempotent entry for #{inspect(config.name)}: #{Exception.message(error)}"
        end
      end)
      |> MapSet.new()

    %__MODULE__{
      config: config,
      table: table,
      idempotent: idempotent,
      connections:
        List.to_tuple(for i <- 1..config.pool_size, do: {AshGrpc.Client, config.name, i}),
      counter: :atomics.new(1, signed: false),
      dynamic_supervisor:
        if(config.connect == :lazy, do: Module.concat(config.name, ConnectionSupervisor))
    }
  end

  @doc false
  @spec fetch(atom()) :: {:ok, t()} | {:error, Exception.t()}
  def fetch(name) do
    case :persistent_term.get({AshGrpc.Client, name}, nil) do
      %__MODULE__{} = runtime ->
        {:ok, runtime}

      nil ->
        {:error,
         AshGrpc.Client.Errors.rpc_error(
           :unavailable,
           "gRPC client #{inspect(name)} is not started; add it to your supervision tree"
         )}
    end
  end

  @doc false
  @spec put(t()) :: :ok
  def put(%__MODULE__{config: %{name: name}} = runtime),
    do: :persistent_term.put({AshGrpc.Client, name}, runtime)

  @doc false
  @spec erase(atom()) :: :ok
  def erase(name) do
    :persistent_term.erase({AshGrpc.Client, name})
    :ok
  end

  defmodule Keeper do
    @moduledoc false
    # Owns the persistent_term entry: published on start, erased on shutdown.
    use GenServer

    def start_link(runtime), do: GenServer.start_link(__MODULE__, runtime)

    @impl true
    def init(runtime) do
      Process.flag(:trap_exit, true)
      AshGrpc.Client.Runtime.put(runtime)
      {:ok, runtime.config.name}
    end

    @impl true
    def terminate(_reason, name), do: AshGrpc.Client.Runtime.erase(name)
  end
end
