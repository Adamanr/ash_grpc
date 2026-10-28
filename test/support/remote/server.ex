defmodule AshGrpc.Test.Remote.Store do
  @moduledoc false
  # ETS-backed state of the fake ticket service, plus a log of received requests.

  @table __MODULE__

  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
    end

    :ok
  end

  def reset! do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def put(%{id: id} = ticket), do: :ets.insert(@table, {{:ticket, id}, ticket})
  def delete(id), do: :ets.delete(@table, {:ticket, id})

  def get(id) do
    case :ets.lookup(@table, {:ticket, id}) do
      [{_, ticket}] -> ticket
      [] -> nil
    end
  end

  def all do
    @table
    |> :ets.match_object({{:ticket, :_}, :_})
    |> Enum.map(&elem(&1, 1))
  end

  def log(rpc, request, headers) do
    :ets.insert(@table, {{:log, System.unique_integer([:monotonic])}, {rpc, request, headers}})
  end

  def calls(rpc \\ nil) do
    @table
    |> :ets.match_object({{:log, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(fn {name, _, _} -> is_nil(rpc) or name == rpc end)
    |> Enum.map(fn {_, request, headers} -> {request, headers} end)
  end
end

defmodule AshGrpc.Test.Remote.Server do
  @moduledoc false
  use GRPC.Server, service: AshGrpc.Test.Remote.Proto.TicketService.Service

  alias AshGrpc.Test.Remote.Proto.{
    EscalateResponse,
    ListTicketsResponse,
    Ticket,
    WhoAmIResponse
  }

  alias AshGrpc.Test.Remote.Store

  def list_tickets(request, stream) do
    log(:list_tickets, request, stream)

    tickets =
      Store.all()
      |> Enum.filter(&matches?(&1, request))
      |> Enum.sort_by(& &1.id)

    offset = if request.page_token == "", do: 0, else: String.to_integer(request.page_token)
    size = if request.page_size > 0, do: request.page_size, else: 10
    page = tickets |> Enum.drop(offset) |> Enum.take(size)
    next = if offset + size < length(tickets), do: Integer.to_string(offset + size), else: ""

    %ListTicketsResponse{tickets: page, next_page_token: next}
  end

  defp matches?(ticket, request) do
    (request.owner_id == "" or ticket.owner_id == request.owner_id) and
      (request.status == :TICKET_STATUS_UNSPECIFIED or ticket.status == request.status)
  end

  def get_ticket(request, stream) do
    log(:get_ticket, request, stream)
    Store.get(request.id) || raise not_found(request.id)
  end

  def create_ticket(%{ticket: ticket} = request, stream) do
    log(:create_ticket, request, stream)
    validate!(ticket)
    ticket = %{ticket | created_at: ticket.created_at || now()}
    Store.put(ticket)
    ticket
  end

  def update_ticket(%{ticket: ticket, update_mask: mask} = request, stream) do
    log(:update_ticket, request, stream)
    existing = Store.get(ticket.id) || raise not_found(ticket.id)

    updated =
      Enum.reduce(mask.paths, existing, fn path, acc ->
        key = String.to_existing_atom(path)
        Map.put(acc, key, Map.fetch!(ticket, key))
      end)

    validate!(updated)
    Store.put(updated)
    updated
  end

  def delete_ticket(request, stream) do
    log(:delete_ticket, request, stream)
    Store.get(request.id) || raise not_found(request.id)
    Store.delete(request.id)
    %Google.Protobuf.Empty{}
  end

  def escalate(request, stream) do
    log(:escalate, request, stream)

    if request.level <= 0 do
      raise invalid([{"level", "must be positive"}])
    end

    ticket = Store.get(request.ticket_id) || raise not_found(request.ticket_id)
    ticket = %{ticket | priority: ticket.priority + request.level}
    Store.put(ticket)
    %EscalateResponse{ticket: ticket, note: "escalated to #{ticket.priority}"}
  end

  def who_am_i(request, stream) do
    headers = log(:who_am_i, request, stream)
    %WhoAmIResponse{actor: headers["x-actor"] || "", tenant: headers["x-tenant"] || ""}
  end

  defp log(rpc, request, stream) do
    headers = GRPC.Stream.get_headers(stream)
    Store.log(rpc, request, headers)
    headers
  end

  defp validate!(%Ticket{title: title}) do
    if title in [nil, ""], do: raise(invalid([{"ticket.title", "must be present"}]))
    :ok
  end

  defp now do
    %Google.Protobuf.Timestamp{seconds: 1_700_000_000, nanos: 0}
  end

  defp not_found(id) do
    GRPC.RPCError.exception(
      status: GRPC.Status.not_found(),
      message: "ticket #{id} not found",
      details: [
        AshGrpc.Error.Details.pack(%Google.Rpc.ResourceInfo{
          resource_type: "ash_grpc.test.remote.v1.Ticket",
          resource_name: id
        })
      ]
    )
  end

  defp invalid(violations) do
    GRPC.RPCError.exception(
      status: GRPC.Status.invalid_argument(),
      message: "invalid request",
      details: [
        AshGrpc.Error.Details.pack(%Google.Rpc.BadRequest{
          field_violations:
            Enum.map(violations, fn {field, description} ->
              %Google.Rpc.BadRequest.FieldViolation{field: field, description: description}
            end)
        })
      ]
    )
  end
end

defmodule AshGrpc.Test.Remote.Endpoint do
  @moduledoc false
  use GRPC.Endpoint

  run AshGrpc.Test.Remote.Server
end

defmodule AshGrpc.Test.Remote.Client do
  @moduledoc false
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [AshGrpc.Test.Remote.Proto.TicketService.Service]
end

defmodule AshGrpc.Test.Remote.SandboxClient do
  @moduledoc false
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [AshGrpc.Test.Remote.Proto.TicketService.Service],
    sandbox: true
end

defmodule AshGrpc.Test.Remote.OpsSandboxClient do
  @moduledoc false
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [AshGrpc.Test.Remote.Proto.TicketService.Service],
    sandbox: true
end
