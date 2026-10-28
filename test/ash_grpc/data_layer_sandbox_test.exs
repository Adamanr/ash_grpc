defmodule AshGrpc.DataLayerSandboxTest do
  # The data layer against a sandboxed client: exact requests and responses.
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshGrpc.Client.Sandbox
  alias AshGrpc.Test.Remote.Proto.{ListTicketsRequest, ListTicketsResponse, Ticket}
  alias AshGrpc.Test.Remote.{SandboxClient, SandboxTicket}

  @moduletag :capture_log

  setup_all do
    start_supervised!(SandboxClient)
    :ok
  end

  setup context, do: Sandbox.verify_on_exit!(context)

  defp page(ids, next),
    do: %ListTicketsResponse{tickets: Enum.map(ids, &%Ticket{id: &1}), next_page_token: next}

  test "follows page tokens" do
    Sandbox.expect(SandboxClient, :list_tickets, fn %ListTicketsRequest{
                                                      page_token: "",
                                                      page_size: 3
                                                    } ->
      page(["a", "b", "c"], "p2")
    end)

    Sandbox.expect(SandboxClient, :list_tickets, fn %ListTicketsRequest{page_token: "p2"} ->
      page(["d"], "")
    end)

    assert ~w(a b c d) = SandboxTicket |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "stops at max_pages" do
    Sandbox.expect(SandboxClient, :list_tickets, 2, fn %{page_token: token} ->
      page([token <> "x"], token <> "n")
    end)

    assert ["x", "nx"] = SandboxTicket |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "pushes down filters and maps INVALID_ARGUMENT to field errors" do
    Sandbox.expect(SandboxClient, :list_tickets, fn %{owner_id: "u1"} -> page([], "") end)
    assert [] = SandboxTicket |> Ash.Query.filter(owner_id == "u1") |> Ash.read!()

    violation =
      AshGrpc.Error.Details.pack(%Google.Rpc.BadRequest{
        field_violations: [
          %Google.Rpc.BadRequest.FieldViolation{
            field: "ticket.owner_id",
            description: "unknown owner"
          }
        ]
      })

    Sandbox.expect(SandboxClient, :create_ticket, fn _ ->
      {:error, GRPC.RPCError.exception(status: 3, message: "bad", details: [violation])}
    end)

    assert {:error, %Ash.Error.Invalid{errors: [error]}} =
             SandboxTicket
             |> Ash.Changeset.for_create(:create, %{id: "x", title: "t", owner_id: "nobody"})
             |> Ash.create()

    assert %Ash.Error.Changes.InvalidAttribute{field: :owner_id, message: "unknown owner"} = error
  end

  test "server errors on reads are returned" do
    Sandbox.expect(SandboxClient, :list_tickets, fn _ -> {:error, :permission_denied} end)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(SandboxTicket)
  end
end
