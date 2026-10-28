defmodule FrontdeskTest do
  # Both services in one VM, talking over a real socket: Frontdesk (AshGrpc.DataLayer and
  # AshGrpc.Rpc) → gRPC → Library (AshGrpc.Endpoint).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Ash.Query

  @librarian %{name: "ada"}

  setup do
    Ash.DataLayer.Ets.stop(Library.Book)

    for child <- AshGrpcExample.Application.children(:library, port: 0),
        do: start_supervised!(child)

    port = AshGrpc.Server.port(Library.GrpcEndpoint)

    for child <- AshGrpcExample.Application.children(:frontdesk, address: "127.0.0.1:#{port}"),
        do: start_supervised!(child)

    :ok
  end

  test "librarians add books, the library records who added them" do
    book = Frontdesk.add_book!("Dune", %{author: "Herbert", genre: :fiction}, actor: @librarian)

    assert %Frontdesk.Book{title: "Dune", genre: :fiction, copies: 1, added_by: "ada"} = book
    assert %DateTime{} = book.inserted_at

    # the record lives in the library service
    assert [%Library.Book{title: "Dune", added_by: "ada"}] =
             Ash.read!(Library.Book, authorize?: false)
  end

  test "anonymous callers cannot add books" do
    assert {:error, %Ash.Error.Forbidden{}} = Frontdesk.add_book("Anonymous")
  end

  test "reads, filters, updates and deletes go through the library service" do
    for {title, author, genre} <- [
          {"Dune", "Herbert", :fiction},
          {"Cosmos", "Sagan", :science},
          {"Contact", "Sagan", :fiction}
        ] do
      Frontdesk.add_book!(title, %{author: author, genre: genre}, actor: @librarian)
    end

    assert Frontdesk.list_books!() |> Enum.map(& &1.title) |> Enum.sort() ==
             ["Contact", "Cosmos", "Dune"]

    # author and genre are sent to ListBooks; the title filter runs on the front desk
    assert [%{title: "Contact"}] =
             Frontdesk.Book
             |> Ash.Query.filter(author == "Sagan" and genre == :fiction)
             |> Ash.read!()

    assert [%{title: "Cosmos"}] =
             Frontdesk.Book |> Ash.Query.filter(contains(title, "osm")) |> Ash.read!()

    dune = Frontdesk.Book |> Ash.Query.filter(title == "Dune") |> Ash.read_one!()
    assert Frontdesk.get_book!(dune.id).title == "Dune"

    restocked = Frontdesk.restock!(dune, 4, actor: @librarian)
    assert restocked.copies == 5
    assert Frontdesk.get_book!(dune.id, load: :available?).available?

    assert Frontdesk.count_available!() == 7

    assert :ok = Frontdesk.remove_book!(dune, actor: @librarian)
    assert Frontdesk.count_available!() == 2
  end

  test "server-side validation errors come back as field errors" do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Frontdesk.add_book("Dune", %{copies: -1}, actor: @librarian)

    assert Enum.any?(errors, &match?(%{field: :copies}, &1))
  end
end
