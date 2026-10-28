defmodule AshGrpc.RpcTest do
  # Generic actions calling the fixture TicketService through AshGrpc.Rpc.
  use AshGrpc.Test.Remote.Case, async: false

  @moduletag :capture_log

  defp run(action, args, opts \\ []) do
    Ops
    |> Ash.ActionInput.for_action(action, args, opts)
    |> Ash.run_action()
  end

  setup do
    seed([ticket(id: "t1", title: "one", priority: 1)])
    :ok
  end

  test "arguments are mapped to request fields, the whole response is decoded" do
    assert {:ok, %{note: "escalated to 3", ticket: %{id: "t1", priority: 3}}} =
             run(:escalate, %{ticket_id: "t1", level: 2})

    assert [{%Proto.EscalateRequest{ticket_id: "t1", level: 2}, _}] = Store.calls(:escalate)
  end

  test "a response field path is decoded to the return type" do
    assert {:ok, "escalated to 2"} = run(:escalate_note, %{ticket_id: "t1"})
  end

  test "messages decode into resources (struct + instance_of)" do
    assert {:ok, %Ticket{id: "t1", title: "one", priority: 3, status: :open}} =
             run(:escalate_ticket, %{id: "t1"})
  end

  test "request and response functions" do
    assert {:ok, 2} = run(:priority_after, %{ticket_id: "t1"})
  end

  test "NOT_FOUND becomes Ash.Error.Query.NotFound" do
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             run(:escalate, %{ticket_id: "missing"})
  end

  test "field violations are reported on the arguments" do
    assert {:error, %Ash.Error.Invalid{errors: [error]}} =
             run(:escalate, %{ticket_id: "t1", level: 0})

    assert %Ash.Error.Changes.InvalidAttribute{field: :level, message: "must be positive"} = error
  end

  test "actor and tenant reach the metadata" do
    assert {:ok, %{actor: "user-7", tenant: "acme"}} =
             run(:who_am_i, %{}, actor: %{id: "user-7"}, tenant: "acme")

    assert [{_, %{"x-actor" => "user-7", "x-tenant" => "acme"}}] = Store.calls(:who_am_i)
  end
end

defmodule AshGrpc.RpcSandboxTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Client.Sandbox
  alias AshGrpc.Test.Remote.{Ops, OpsSandboxClient}
  alias AshGrpc.Test.Remote.Proto.{WhoAmIRequest, WhoAmIResponse}

  setup_all do
    start_supervised!(OpsSandboxClient)
    :ok
  end

  setup context, do: Sandbox.verify_on_exit!(context)

  test "actions without a return type return :ok; deadline is passed" do
    Sandbox.expect(OpsSandboxClient, :who_am_i, fn %WhoAmIRequest{}, %{deadline: deadline} ->
      assert deadline > 0
      %WhoAmIResponse{}
    end)

    assert :ok = Ops |> Ash.ActionInput.for_action(:ping, %{}) |> Ash.run_action()
  end

  test "transport errors are returned as Ash errors" do
    Sandbox.expect(OpsSandboxClient, :who_am_i, fn _ -> {:error, {:unavailable, "down"}} end)

    assert {:error, %Ash.Error.Unknown{}} =
             Ops |> Ash.ActionInput.for_action(:ping, %{}) |> Ash.run_action()
  end
end
