defmodule AshGrpc.E2E.RemoteResourceTest do
  # Ash on both ends: AshGrpc.DataLayer resources (RemoteBook, RemoteNote) backed by the
  # resources served by AshGrpc.Test.E2E.Endpoint, over a real socket.
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshGrpc.Test.E2E.{Book, Endpoint, LibraryClient, Note, RemoteBook, RemoteNote}

  @moduletag :e2e
  @moduletag :capture_log

  @alice %{id: "alice"}
  @bob %{id: "bob"}

  setup_all do
    start_supervised!({AshGrpc.Server, endpoint: Endpoint, port: 0})
    %{port: AshGrpc.Server.port(Endpoint)}
  end

  setup %{port: port} do
    Ash.DataLayer.Ets.stop(Book)
    Ash.DataLayer.Ets.stop(Note)
    start_supervised!({LibraryClient, address: "127.0.0.1:#{port}"})
    :ok
  end

  defp create_book!(attrs) do
    RemoteBook
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  # what the server stores, read directly on the serving side
  defp served_book(id), do: Ash.get!(Book, id)

  describe "CRUD" do
    test "create, read, get, update and destroy go through the served resource" do
      book = create_book!(%{title: "Dune", author: "Herbert", pages: 412, tags: ["sf"]})

      assert %RemoteBook{title: "Dune", status: :draft, headline: "Dune by Herbert"} = book
      assert %DateTime{} = book.inserted_at
      assert served_book(book.id).title == "Dune"

      assert [%RemoteBook{id: id}] = Ash.read!(RemoteBook)
      assert id == book.id
      assert RemoteBook.get!(book.id).title == "Dune"

      updated =
        book
        |> Ash.Changeset.for_update(:update, %{title: "Dune Messiah", status: :published})
        |> Ash.update!()

      assert updated.title == "Dune Messiah"
      assert updated.status == :published
      # the update mask only carried the changed attributes
      assert %{title: "Dune Messiah", pages: 412, author: "Herbert"} = served_book(book.id)

      assert :ok = Ash.destroy!(updated)
      assert Ash.read!(RemoteBook) == []
      assert {:error, %Ash.Error.Invalid{}} = RemoteBook.get(book.id)
    end

    test "reads follow pages and calculations are computed on the client" do
      for i <- 1..5, do: create_book!(%{title: "Vol #{i}", pages: i * 100})

      # page_size 2 on the remote resource: five records take three calls
      books = RemoteBook |> Ash.Query.sort(:title) |> Ash.Query.load(:long?) |> Ash.read!()
      assert Enum.map(books, & &1.title) == ["Vol 1", "Vol 2", "Vol 3", "Vol 4", "Vol 5"]
      assert Enum.map(books, & &1.long?) == [false, false, false, true, true]

      page = RemoteBook |> Ash.Query.sort(:title) |> Ash.read!(page: [limit: 2, offset: 2])
      assert Enum.map(page.results, & &1.title) == ["Vol 3", "Vol 4"]
    end

    test "server-side validation errors become field errors" do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               RemoteBook
               |> Ash.Changeset.for_create(:create, %{title: "Short", pages: 0})
               |> Ash.create()

      assert Enum.any?(errors, &match?(%{field: :pages}, &1))
    end
  end

  describe "filters" do
    setup do
      create_book!(%{title: "Foundation", author: "Asimov", pages: 255, status: :published})
      create_book!(%{title: "I, Robot", author: "Asimov", pages: 253})
      create_book!(%{title: "Dune", author: "Herbert", pages: 412, status: :published})
      :ok
    end

    test "equality filters are pushed down, the rest is applied in memory" do
      asimov = RemoteBook |> Ash.Query.filter(author == "Asimov") |> Ash.read!()
      assert asimov |> Enum.map(& &1.title) |> Enum.sort() == ["Foundation", "I, Robot"]

      assert [%{title: "Foundation"}] =
               RemoteBook
               |> Ash.Query.filter(author == "Asimov" and status == :published)
               |> Ash.read!()

      # not pushed down (no request field), still correct
      assert [%{title: "Dune"}] = RemoteBook |> Ash.Query.filter(pages > 300) |> Ash.read!()

      assert [%{title: "Foundation"}] =
               RemoteBook
               |> Ash.Query.filter(author == "Asimov" and contains(title, "Found"))
               |> Ash.read!()
    end
  end

  describe "policies with the actor propagated via metadata" do
    test "the server sees the actor of the Ash call" do
      note =
        RemoteNote
        |> Ash.Changeset.for_create(:create, %{body: "alice's"}, actor: @alice)
        |> Ash.create!()

      assert note.owner_id == "alice"
      assert Ash.get!(Note, note.id, authorize?: false).owner_id == "alice"

      assert [%{body: "alice's"}] = Ash.read!(RemoteNote, actor: @alice)
      assert Ash.read!(RemoteNote, actor: @bob) == []
    end

    test "writes forbidden by the server's policies fail on the client" do
      assert {:error, %Ash.Error.Forbidden{}} =
               RemoteNote
               |> Ash.Changeset.for_create(:create, %{body: "anonymous"})
               |> Ash.create()

      note =
        RemoteNote
        |> Ash.Changeset.for_create(:create, %{body: "mine"}, actor: @alice)
        |> Ash.create!()

      # the server's read policy hides alice's note from bob, so his writes find nothing
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               note
               |> Ash.Changeset.for_update(:update, %{body: "hijacked"}, actor: @bob)
               |> Ash.update()

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Ash.destroy(note, actor: @bob)

      assert Ash.get!(Note, note.id, authorize?: false).body == "mine"

      assert %{body: "edited"} =
               note
               |> Ash.Changeset.for_update(:update, %{body: "edited"}, actor: @alice)
               |> Ash.update!()

      assert :ok = Ash.destroy!(note, actor: @alice)
    end
  end
end
