defmodule AshGrpc.DataLayerTest do
  # Talks to a real GRPC.Server implementing the fixture TicketService.
  use AshGrpc.Test.Remote.Case, async: false

  require Ash.Query

  @moduletag :capture_log

  describe "reads" do
    test "reads every page and decodes records" do
      seed(for i <- 1..5, do: ticket(id: "t#{i}", title: "ticket #{i}", priority: i))

      tickets = Ticket |> Ash.Query.sort(:id) |> Ash.read!()

      assert Enum.map(tickets, & &1.id) == ~w(t1 t2 t3 t4 t5)
      assert %Ticket{owner: "u1", status: :open, priority: 1, labels: []} = hd(tickets)

      # page_size 2 → 3 pages
      assert [
               {%{page_size: 2, page_token: ""}, _},
               {%{page_size: 2, page_token: "2"}, _},
               {%{page_size: 2, page_token: "4"}, _}
             ] = Store.calls(:list_tickets)
    end

    test "decodes timestamps, optional and repeated fields" do
      seed([
        ticket(
          id: "t1",
          created_at: %Google.Protobuf.Timestamp{seconds: 1_700_000_000},
          description: "desc",
          labels: ["a", "b"]
        )
      ])

      assert [ticket] = Ash.read!(Ticket)
      assert ticket.created_at == ~U[2023-11-14 22:13:20Z]
      assert ticket.description == "desc"
      assert ticket.labels == ["a", "b"]
    end

    test "stops paging once limit is reached when there is no sort" do
      seed(for i <- 1..9, do: ticket(id: "t#{i}"))

      assert [_, _, _] = Ticket |> Ash.Query.limit(3) |> Ash.read!()
      assert length(Store.calls(:list_tickets)) == 2

      # with a sort every page is needed
      Store.reset!()
      seed(for i <- 1..9, do: ticket(id: "t#{i}", priority: 10 - i))

      assert ["t9", "t8"] =
               Ticket
               |> Ash.Query.sort(:priority)
               |> Ash.Query.limit(2)
               |> Ash.read!()
               |> Enum.map(& &1.id)

      assert length(Store.calls(:list_tickets)) == 5
    end

    test "offset and keyset pagination work on top of the pages" do
      seed(for i <- 1..7, do: ticket(id: "t#{i}"))

      assert %Ash.Page.Offset{results: results} =
               Ticket |> Ash.Query.sort(:id) |> Ash.read!(page: [limit: 2, offset: 4])

      assert Enum.map(results, & &1.id) == ~w(t5 t6)

      page = Ticket |> Ash.Query.sort(:id) |> Ash.read!(page: [limit: 3])
      assert Enum.map(page.results, & &1.id) == ~w(t1 t2 t3)
      next = Ash.page!(page, :next)
      assert Enum.map(next.results, & &1.id) == ~w(t4 t5 t6)
    end

    test "equality filters on declared attributes are pushed down" do
      seed([
        ticket(id: "t1", owner_id: "u1", status: :TICKET_STATUS_OPEN),
        ticket(id: "t2", owner_id: "u1", status: :TICKET_STATUS_CLOSED),
        ticket(id: "t3", owner_id: "u2", status: :TICKET_STATUS_OPEN)
      ])

      assert ["t2"] =
               Ticket
               |> Ash.Query.filter(owner == "u1" and status == :closed)
               |> Ash.read!()
               |> Enum.map(& &1.id)

      assert [{%{owner_id: "u1", status: :TICKET_STATUS_CLOSED}, _}] = Store.calls(:list_tickets)
    end

    test "other filters are applied in memory" do
      seed([
        ticket(id: "t1", owner_id: "u1", priority: 1, title: "alpha"),
        ticket(id: "t2", owner_id: "u1", priority: 7, title: "beta"),
        ticket(id: "t3", owner_id: "u2", priority: 9, title: "gamma")
      ])

      assert ["t2"] =
               Ticket
               |> Ash.Query.filter(owner == "u1" and priority > 5)
               |> Ash.read!()
               |> Enum.map(& &1.id)

      # only the owner was sent
      assert [{%{owner_id: "u1", status: :TICKET_STATUS_UNSPECIFIED}, _}] =
               Store.calls(:list_tickets)

      assert ["t1", "t3"] =
               Ticket
               |> Ash.Query.filter(title == "alpha" or contains(title, "mm"))
               |> Ash.Query.sort(:id)
               |> Ash.read!()
               |> Enum.map(& &1.id)

      assert ["t3", "t2"] =
               Ticket
               |> Ash.Query.filter(urgent?)
               |> Ash.Query.sort(priority: :desc)
               |> Ash.Query.load(:urgent?)
               |> Ash.read!()
               |> Enum.map(& &1.id)
    end

    test "strict_filters? rejects filters that cannot be pushed down" do
      seed([ticket(id: "t1", owner_id: "u1"), ticket(id: "t2", owner_id: "u2")])

      assert [%StrictTicket{id: "t1"}] =
               StrictTicket |> Ash.Query.filter(owner_id == "u1") |> Ash.read!()

      assert {:error, %Ash.Error.Invalid{errors: [%AshGrpc.DataLayer.UnsupportedFilter{}]}} =
               StrictTicket |> Ash.Query.filter(title == "T") |> Ash.read()
    end

    test "get by primary key goes through the get rpc" do
      seed([ticket(id: "t1", title: "one"), ticket(id: "t2")])

      assert %Ticket{id: "t1", title: "one"} = Ash.get!(Ticket, "t1")
      assert [{%{id: "t1"}, _}] = Store.calls(:get_ticket)
      assert [] = Store.calls(:list_tickets)

      # extra conditions are checked in memory
      assert [] = Ticket |> Ash.Query.filter(id == "t1" and title == "other") |> Ash.read!()

      # NOT_FOUND from the get rpc: no record
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Ash.get(Ticket, "missing")
    end
  end

  describe "writes" do
    test "full CRUD" do
      ticket =
        Ticket
        |> Ash.Changeset.for_create(:create, %{
          title: "new",
          owner: "u9",
          status: :open,
          labels: ["x"]
        })
        |> Ash.create!()

      assert %Ticket{title: "new", owner: "u9", status: :open, labels: ["x"]} = ticket
      # set by the server
      assert ticket.created_at == ~U[2023-11-14 22:13:20Z]

      assert [
               {%{
                  ticket: %Proto.Ticket{title: "new", owner_id: "u9", status: :TICKET_STATUS_OPEN}
                }, _}
             ] =
               Store.calls(:create_ticket)

      assert %Proto.Ticket{title: "new"} = Store.get(ticket.id)

      updated =
        ticket
        |> Ash.Changeset.for_update(:update, %{title: "renamed", status: :closed})
        |> Ash.update!()

      assert %Ticket{title: "renamed", status: :closed, owner: "u9"} = updated

      assert [{%{update_mask: %Google.Protobuf.FieldMask{paths: ["status", "title"]}}, _}] =
               Store.calls(:update_ticket)

      assert %Ticket{title: "renamed"} = Ash.get!(Ticket, ticket.id)

      assert :ok = Ash.destroy!(updated)
      assert [{%{id: id}, _}] = Store.calls(:delete_ticket)
      assert id == ticket.id
      assert is_nil(Store.get(ticket.id))
      assert [] = Ash.read!(Ticket)
    end

    test "INVALID_ARGUMENT field violations become attribute errors" do
      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               Ticket
               |> Ash.Changeset.for_create(:create, %{title: "", owner: "u1"})
               |> Ash.create()

      assert %Ash.Error.Changes.InvalidAttribute{
               field: :title,
               path: [],
               message: "must be present"
             } =
               error
    end

    test "NOT_FOUND on update and destroy becomes Ash.Error.Query.NotFound" do
      seed([ticket(id: "t1")])
      ticket = Ash.get!(Ticket, "t1")
      Store.delete("t1")

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} = not_found]}} =
               ticket |> Ash.Changeset.for_update(:update, %{title: "x"}) |> Ash.update()

      assert not_found.resource == Ticket
      assert not_found.primary_key == %{id: "t1"}

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Ash.destroy(ticket)
    end
  end

  describe "call metadata" do
    test "the actor reaches the client metadata function, the section metadata is sent" do
      seed([ticket(id: "t1")])

      Ash.read!(Ticket, actor: %{id: "user-42"}, tenant: "acme")

      assert [{_request, headers}] = Store.calls(:list_tickets)
      assert headers["x-actor"] == "user-42"
      assert headers["x-tenant"] == "acme"
      assert headers["x-resource"] == "AshGrpc.Test.Remote.Ticket"
      assert headers["x-action"] == "read"
    end
  end

  describe "capabilities" do
    test "only declared rpcs are supported" do
      assert AshGrpc.DataLayer.can?(Ticket, :create)
      refute AshGrpc.DataLayer.can?(StrictTicket, :create)
      refute AshGrpc.DataLayer.can?(StrictTicket, :update)
      refute AshGrpc.DataLayer.can?(Ticket, :transact)
    end
  end
end
