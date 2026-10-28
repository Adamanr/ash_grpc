defmodule AshGrpc.Client.Pool do
  @moduledoc """
  The connection pool of a client.

  The pool is a fixed set of `pool_size` supervised `GRPC.Client.Connection` processes
  (grpc ≥ 1.0). Each of them owns one HTTP/2 connection per resolved address and already
  provides what a production channel needs, so AshGrpc reuses it instead of reimplementing it:

    * name resolution (`dns:///`, `ipv4:`, `unix:` …) with periodic DNS re-resolution,
    * load balancing across resolved addresses (`:lb_policy`, `:round_robin` by default),
    * establishment in the background with exponential backoff, never failing the supervisor,
    * re-dialing a dropped connection (Mint adapter `retry`, from `:reconnect_attempts`).

  On top of that the pool adds round-robin across the `pool_size` connections (an `:atomics`
  counter, no process hop), lazy dialing (`connect: :lazy`), bounded waiting for a connection
  that is still being established (`:connect_timeout`, capped by the call deadline) and
  `health/1`.
  """

  alias AshGrpc.Client.{Config, Errors, Runtime}
  alias GRPC.Client.Connection

  @typedoc "Health of a single pooled connection."
  @type connection_status :: :ready | :connecting | :idle

  @doc "Child specs of the pooled connections started eagerly with the client supervisor."
  @spec child_specs(Runtime.t()) :: [Supervisor.child_spec()]
  def child_specs(%Runtime{config: %Config{connect: :lazy}} = runtime) do
    [{DynamicSupervisor, name: runtime.dynamic_supervisor, strategy: :one_for_one}]
  end

  def child_specs(%Runtime{} = runtime) do
    runtime.connections
    |> Tuple.to_list()
    |> Enum.map(&connection_spec(runtime.config, &1))
  end

  defp connection_spec(%Config{} = config, name) do
    Connection.child_spec({config.address, connect_opts(config, name)})
  end

  @doc false
  @spec connect_opts(Config.t(), term()) :: keyword()
  def connect_opts(%Config{} = config, name) do
    reconnect =
      case config.reconnect_attempts do
        :infinity -> 1_000_000_000
        n -> n
      end

    [
      name: name,
      adapter: config.adapter,
      adapter_opts: Keyword.put_new(config.adapter_opts, :retry, reconnect),
      interceptors: config.interceptors,
      codec: config.codec,
      compressor: config.compression,
      lb_policy: config.lb_policy,
      connect_timeout: config.connect_timeout
    ]
    |> then(fn opts -> if config.tls, do: Keyword.put(opts, :cred, config.tls), else: opts end)
  end

  @doc """
  Checks out a channel for one call: picks the next pooled connection round-robin, starts it
  if the pool is lazy, and waits up to `timeout` ms for it to be established.

  The returned channel is a real (connected) channel, usable with `GRPC.Stub` directly.
  """
  @spec checkout(Runtime.t(), timeout()) :: {:ok, GRPC.Channel.t()} | {:error, GRPC.RPCError.t()}
  def checkout(%Runtime{} = runtime, timeout) do
    size = tuple_size(runtime.connections)
    index = rem(:atomics.add_get(runtime.counter, 1, 1), size)
    name = elem(runtime.connections, index)

    with {:ok, virtual} <- ensure_started(runtime, name) do
      case pick(virtual) do
        {:ok, channel} -> {:ok, channel}
        :error -> await_and_pick(runtime, virtual, timeout)
      end
    end
  end

  defp await_and_pick(runtime, virtual, timeout) do
    wait = max(min(runtime.config.connect_timeout, timeout), 0)

    with :ok <- Connection.await_ready(virtual, wait),
         {:ok, channel} <- pick(virtual) do
      {:ok, channel}
    else
      _ -> {:error, unavailable(runtime)}
    end
  end

  defp pick(virtual) do
    case Connection.pick_channel(virtual) do
      {:ok, %GRPC.Channel{adapter_payload: %{conn_pid: pid}} = channel} when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, channel}, else: :error

      {:ok, %GRPC.Channel{} = channel} ->
        {:ok, channel}

      _ ->
        :error
    end
  end

  defp ensure_started(%Runtime{dynamic_supervisor: nil} = runtime, name) do
    case Connection.get_channel(name) do
      {:ok, channel} -> {:ok, channel}
      {:error, _} -> {:error, unavailable(runtime)}
    end
  end

  defp ensure_started(%Runtime{} = runtime, name) do
    case Connection.get_channel(name) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, :not_started} ->
        case DynamicSupervisor.start_child(
               runtime.dynamic_supervisor,
               connection_spec(runtime.config, name)
             ) do
          {:ok, _} -> Connection.get_channel(name)
          {:error, {:already_started, _}} -> Connection.get_channel(name)
          {:error, _} -> {:error, unavailable(runtime)}
        end
    end
  catch
    :exit, _ -> {:error, unavailable(runtime)}
  end

  defp unavailable(runtime) do
    Errors.rpc_error(
      :unavailable,
      "no connection to #{runtime.config.address} for gRPC client #{inspect(runtime.config.name)}"
    )
  end

  @doc """
  Health of the client's connections.

  Returns `:ready` when at least one pooled connection is established, `:connecting` when
  connections are running but none is established yet, `:idle` for a lazy pool that has not
  dialed yet, and per-connection statuses under `:connections`.
  """
  @spec health(Runtime.t()) :: %{
          status: connection_status(),
          connections: [{term(), connection_status()}]
        }
  def health(%Runtime{} = runtime) do
    statuses =
      runtime.connections
      |> Tuple.to_list()
      |> Enum.map(&{&1, connection_status(&1)})

    overall =
      cond do
        Enum.any?(statuses, &match?({_, :ready}, &1)) -> :ready
        Enum.any?(statuses, &match?({_, :connecting}, &1)) -> :connecting
        true -> :idle
      end

    %{status: overall, connections: statuses}
  end

  defp connection_status(name) do
    case Connection.get_channel(name) do
      {:ok, virtual} -> if match?({:ok, _}, pick(virtual)), do: :ready, else: :connecting
      {:error, _} -> :idle
    end
  end
end
