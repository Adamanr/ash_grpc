defmodule AshGrpc.Client.Sandbox do
  @moduledoc """
  Test double for `AshGrpc.Client`s: per-test expectations instead of a network.

  Enable it for a client in `config/test.exs`; the client then opens no connection and every
  call is answered by an expectation or stub defined by the test:

      config :my_app, MyApp.Billing, sandbox: true

      test "charges the card" do
        AshGrpc.Client.Sandbox.expect(MyApp.Billing, :charge, fn %ChargeRequest{amount: 100} ->
          {:ok, %ChargeResponse{id: "ch_1"}}
        end)

        assert {:ok, %{id: "ch_1"}} = MyApp.Billing.call(:charge, %{amount: 100})
        AshGrpc.Client.Sandbox.verify!()
      end

  Everything above the transport still runs: rpc resolution, request building, deadlines,
  metadata, retries, telemetry and error mapping. So a test can, e.g., return
  `{:error, :unavailable}` from the first expectation and check that the call is retried.

  ## Ownership

  Expectations belong to the process that defined them (the test process) and are visible to
  processes started from it (found through `$callers`, so `Task`s and most Ash internals work
  out of the box). Other processes can be allowed with `allow/2`. Tests using the sandbox can
  therefore be `async: true`.

  ## Expectation functions

  The function receives the request (unary and server streaming), the list of requests
  (client streaming) or the request enumerable (bidirectional streaming); arity-2 functions
  also receive a map with `:client`, `:rpc`, `:metadata`, `:deadline` (remaining ms) and
  `:opts`. They return:

    * `{:ok, response}` or a bare response struct (unary and client streaming),
    * `{:ok, enumerable}` or a list (server and bidirectional streaming),
    * `{:error, %GRPC.RPCError{}}`, `{:error, status}` (a snake_case status atom such as
      `:not_found`) or `{:error, {status, message}}`.

  A call without a matching expectation or stub raises
  `AshGrpc.Client.Sandbox.UnexpectedCallError`.
  """

  use GenServer

  alias AshGrpc.Client.{Errors, RpcTable, Runtime}

  defmodule UnexpectedCallError do
    @moduledoc "Raised when a sandboxed client is called without a matching expectation."
    defexception [:message]
  end

  defmodule VerificationError do
    @moduledoc "Raised by `AshGrpc.Client.Sandbox.verify!/1` when expectations were not met."
    defexception [:message]
  end

  @type rpc :: atom() | String.t() | {module(), atom() | String.t()}

  # -- public API --------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Expects `rpc` of `client` to be called `count` times (default 1), answered by `fun`.
  Expectations for the same rpc are consumed in order.
  """
  @spec expect(atom(), rpc(), pos_integer(), function()) :: :ok
  def expect(client, rpc, count \\ 1, fun)
      when is_integer(count) and count > 0 and (is_function(fun, 1) or is_function(fun, 2)) do
    register({:expect, self(), key(client, rpc), count, fun})
  end

  @doc "Answers every call of `rpc` of `client` with `fun` (after expectations are used up)."
  @spec stub(atom(), rpc(), function()) :: :ok
  def stub(client, rpc, fun) when is_function(fun, 1) or is_function(fun, 2) do
    register({:stub, self(), key(client, rpc), fun})
  end

  @doc "Allows `allowed` (a pid) to use the expectations owned by `owner`."
  @spec allow(pid(), pid()) :: :ok
  def allow(owner, allowed) when is_pid(owner) and is_pid(allowed) do
    register({:allow, owner, allowed})
  end

  @doc "Raises `VerificationError` when expectations of `owner` were not fully consumed."
  @spec verify!(pid()) :: :ok
  def verify!(owner \\ self()) do
    ensure_started()

    case GenServer.call(__MODULE__, {:pending, owner}) do
      [] ->
        :ok

      pending ->
        details =
          Enum.map_join(pending, "\n", fn {{client, path}, count} ->
            "  * #{inspect(client)} #{path}: #{count} call(s) missing"
          end)

        raise VerificationError, "expected calls were not made:\n" <> details
    end
  end

  @doc """
  Verifies the expectations of the current test when it exits. Use as `setup`:

      setup :verify_on_exit!
  """
  @spec verify_on_exit!(map()) :: :ok
  def verify_on_exit!(_context \\ %{}) do
    owner = self()
    # The owner exits before on_exit callbacks run: keep its expectations until verified.
    register({:keep, owner})

    ExUnit.Callbacks.on_exit(__MODULE__, fn ->
      try do
        verify!(owner)
      after
        GenServer.call(__MODULE__, {:cleanup, owner})
      end
    end)
  end

  @doc false
  # Called by `AshGrpc.Client.Call` for every attempt of a sandboxed client.
  @spec dispatch(map(), term()) :: term()
  def dispatch(ctx, request) do
    ensure_started()
    key = {ctx.client, ctx.entry.path}
    pids = [self() | Process.get(:"$callers", [])]

    case GenServer.call(__MODULE__, {:fetch, pids, key}) do
      {:ok, fun} ->
        request =
          if ctx.entry.grpc_type == :client_stream, do: Enum.to_list(request), else: request

        fun
        |> apply_fun(request, ctx)
        |> normalize(ctx.entry.grpc_type)

      :none ->
        raise UnexpectedCallError,
              "unexpected call to #{inspect(ctx.client)} #{ctx.entry.path} " <>
                "(no AshGrpc.Client.Sandbox expectation or stub for #{inspect(self())})"
    end
  end

  defp apply_fun(fun, request, _ctx) when is_function(fun, 1), do: fun.(request)

  defp apply_fun(fun, request, ctx) do
    fun.(request, %{
      client: ctx.client,
      rpc: ctx.entry.name,
      metadata: ctx.metadata,
      deadline: ctx.deadline_at - System.monotonic_time(:millisecond),
      opts: ctx.opts
    })
  end

  defp normalize({:error, status}, _type) when is_atom(status),
    do: {:error, Errors.rpc_error(status, "sandbox: #{status}")}

  defp normalize({:error, {status, message}}, _type) when is_atom(status),
    do: {:error, Errors.rpc_error(status, message)}

  defp normalize({:error, _} = error, _type), do: error
  defp normalize({:ok, _} = ok, _type), do: ok

  defp normalize(list, type)
       when is_list(list) and type in [:server_stream, :bidirectional_stream],
       do: {:ok, list}

  defp normalize(%{__struct__: _} = response, _type), do: {:ok, response}

  defp normalize(other, _type),
    do: raise(ArgumentError, "invalid sandbox expectation result: #{inspect(other)}")

  defp key(client, rpc) do
    case Runtime.fetch(client) do
      {:ok, runtime} ->
        case RpcTable.fetch(runtime.table, rpc) do
          {:ok, entry} -> {client, entry.path}
          {:error, error} -> raise error
        end

      {:error, _} ->
        raise ArgumentError,
              "gRPC client #{inspect(client)} is not started; start it (with sandbox: true) before defining expectations"
    end
  end

  defp register(message) do
    ensure_started()
    GenServer.call(__MODULE__, message)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  # -- server ------------------------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{owners: %{}, allowed: %{}, monitors: %{}, keep: MapSet.new()}}

  @impl true
  def handle_call({:expect, owner, key, count, fun}, _from, state) do
    state =
      state
      |> monitor(owner)
      |> update_owner(owner, fn data ->
        update_in(data, [:expectations, Access.key(key, [])], &(&1 ++ [{count, fun}]))
      end)

    {:reply, :ok, state}
  end

  def handle_call({:stub, owner, key, fun}, _from, state) do
    state =
      state
      |> monitor(owner)
      |> update_owner(owner, &put_in(&1, [:stubs, key], fun))

    {:reply, :ok, state}
  end

  def handle_call({:allow, owner, allowed}, _from, state) do
    state = state |> monitor(owner) |> monitor(allowed)
    {:reply, :ok, put_in(state, [:allowed, allowed], owner)}
  end

  def handle_call({:fetch, pids, key}, _from, state) do
    owner = find_owner(state, pids)

    case Map.fetch(state.owners, owner) do
      :error ->
        {:reply, :none, state}

      {:ok, _data} ->
        {reply, data} = take(state.owners[owner], key)
        {:reply, reply, put_in(state, [:owners, owner], data)}
    end
  end

  def handle_call({:keep, owner}, _from, state) do
    {:reply, :ok, %{monitor(state, owner) | keep: MapSet.put(state.keep, owner)}}
  end

  def handle_call({:cleanup, owner}, _from, state) do
    {:reply, :ok, drop_owner(%{state | keep: MapSet.delete(state.keep, owner)}, owner)}
  end

  def handle_call({:pending, owner}, _from, state) do
    {:reply, pending(state.owners[owner]), state}
  end

  defp find_owner(state, pids) do
    Enum.find_value(pids, fn pid ->
      if Map.has_key?(state.owners, pid), do: pid, else: state.allowed[pid]
    end)
  end

  # Pops the next expectation for `key`, falling back to the stub.
  defp take(data, key) do
    case Map.get(data.expectations, key, []) do
      [{count, fun} | rest] ->
        remaining = if count > 1, do: [{count - 1, fun} | rest], else: rest
        {{:ok, fun}, put_in(data, [:expectations, key], remaining)}

      [] ->
        case Map.fetch(data.stubs, key) do
          {:ok, fun} -> {{:ok, fun}, data}
          :error -> {:none, data}
        end
    end
  end

  defp pending(nil), do: []

  defp pending(data) do
    for {key, list} <- data.expectations,
        count = Enum.reduce(list, 0, fn {n, _}, acc -> acc + n end),
        count > 0,
        do: {key, count}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | monitors: Map.delete(state.monitors, pid)}

    if MapSet.member?(state.keep, pid) do
      {:noreply, state}
    else
      {:noreply, drop_owner(state, pid)}
    end
  end

  defp drop_owner(state, pid) do
    %{
      state
      | owners: Map.delete(state.owners, pid),
        allowed:
          state.allowed
          |> Map.delete(pid)
          |> Map.reject(fn {_allowed, owner} -> owner == pid end)
    }
  end

  defp monitor(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      put_in(state, [:monitors, pid], Process.monitor(pid))
    end
  end

  defp update_owner(state, owner, fun) do
    data = Map.get(state.owners, owner, %{expectations: %{}, stubs: %{}})
    put_in(state, [:owners, owner], fun.(data))
  end
end
