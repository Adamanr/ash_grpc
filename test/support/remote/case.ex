defmodule AshGrpc.Test.Remote.Case do
  @moduledoc false
  # Starts the fake ticket service on a random port and the client pointing at it.
  use ExUnit.CaseTemplate

  alias AshGrpc.Test.Remote.{Client, Endpoint, Store}

  using do
    quote do
      import AshGrpc.Test.Remote.Case
      alias AshGrpc.Test.Remote.{Ops, Store, StrictTicket, Ticket}
      alias AshGrpc.Test.Remote.Proto
    end
  end

  setup_all do
    Store.ensure_table()

    {:ok, _pid, port} =
      GRPC.Server.start_endpoint(Endpoint, 0, exception_log_filter: {__MODULE__, :log?})

    on_exit(fn -> GRPC.Server.stop_endpoint(Endpoint) end)
    %{port: port}
  end

  setup %{port: port} do
    Store.reset!()

    start_supervised!(
      {Client,
       address: "127.0.0.1:#{port}",
       metadata: fn %{opts: opts} ->
         actor = opts[:actor]
         %{"x-actor" => (actor && actor.id) || "", "x-tenant" => to_string(opts[:tenant] || "")}
       end}
    )

    :ok
  end

  # expected server-side errors would only add noise
  def log?(_exception), do: false

  def ticket(attrs) do
    struct(
      AshGrpc.Test.Remote.Proto.Ticket,
      Keyword.merge(
        [title: "T", owner_id: "u1", status: :TICKET_STATUS_OPEN, priority: 1, labels: []],
        attrs
      )
    )
  end

  def seed(tickets), do: Enum.each(tickets, &Store.put/1)
end
