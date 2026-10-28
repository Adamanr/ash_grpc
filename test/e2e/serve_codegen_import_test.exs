defmodule AshGrpc.E2E.ServeCodegenImportTest do
  # Serve → codegen → foreign client: the .proto files written by `mix ash_grpc.codegen` are
  # all another team gets. They must pass protoc and buf lint, import back through
  # AshGrpc.Proto.Import, and the client compiled from them must talk to the running server.
  use ExUnit.Case, async: false

  alias AshGrpc.Test.E2E.Endpoint
  alias AshGrpc.Test.Protoc
  alias Google.Rpc.BadRequest

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag :capture_log

  unless Protoc.available?() and Protoc.buf_available?(),
    do: @moduletag(skip: "protoc and buf are required")

  @proto "ashgrpc/e2e/library/v1/library.proto"
  @lock "test/support/e2e/library.lock.json"
  @foreign AshGrpc.Test.E2E.Foreign

  setup_all do
    start_supervised!({AshGrpc.Server, endpoint: Endpoint, port: 0})
    %{port: AshGrpc.Server.port(Endpoint)}
  end

  setup %{tmp_dir: dir, port: port} do
    Ash.DataLayer.Ets.stop(AshGrpc.Test.E2E.Book)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    out = Path.join(dir, "protos")
    lock = Path.join(dir, "lock.json")
    File.cp!(@lock, lock)

    Mix.Task.reenable("ash_grpc.codegen")

    Mix.Tasks.AshGrpc.Codegen.run([
      "--domains",
      "AshGrpc.Test.E2E.Library",
      "--out",
      out,
      "--lock",
      lock,
      "--snapshots",
      Path.join(dir, "snapshots"),
      "--buf",
      "--quiet"
    ])

    %{out: out, lock: lock, port: port}
  end

  defp foreign(name), do: Module.concat(@foreign, name)

  defp import_and_connect!(out, port) do
    {:ok, schema} =
      AshGrpc.Proto.Import.from_files([Path.join(out, @proto)],
        include_paths: [out],
        module_prefix: @foreign
      )

    modules = AshGrpc.Proto.Compiler.compile(schema, [])
    service = foreign("LibraryService.Service")
    assert service in modules

    start_supervised!(
      {AshGrpc.Client,
       name: :e2e_foreign, services: [service], address: "127.0.0.1:#{port}", map_errors: false}
    )

    :ok
  end

  defp call(rpc, request), do: AshGrpc.Client.call(:e2e_foreign, rpc, request)

  test "codegen output is accepted by protoc and buf lint", %{out: out, lock: lock} do
    # the served endpoint was compiled with the same lock: codegen must not renumber anything
    assert File.read!(lock) == File.read!(@lock)

    set = Protoc.descriptor_set!(out, [@proto])
    assert @proto in Enum.map(set.file, & &1.name)

    for args <- [["lint"], ["build"]] do
      assert {"", 0} = System.cmd("buf", args, cd: out, stderr_to_stdout: true)
    end
  end

  test "a client compiled from the imported protos calls the running server",
       %{out: out, port: port} do
    import_and_connect!(out, port)
    book = foreign("Book")

    # unary
    assert {:ok, %{__struct__: ^book} = created} =
             call(:create_book, %{title: "Dune", author: "Herbert", pages: 412, tags: ["sf"]})

    assert created.status == :BOOK_STATUS_DRAFT
    assert created.headline == "Dune by Herbert"
    assert %Google.Protobuf.Timestamp{} = created.inserted_at

    assert {:ok, %{title: "Dune", pages: 412}} = call(:get_book, %{id: created.id})

    # list with pagination: follow next_page_token until the end
    for i <- 1..4, do: {:ok, _} = call(:create_book, %{title: "Vol #{i}", author: "Asimov"})

    assert titles(page_through(%{author: "Asimov", page_size: 3})) |> Enum.sort() ==
             ["Vol 1", "Vol 2", "Vol 3", "Vol 4"]

    assert {:ok, %{books: [_, _], next_page_token: token, total_size: 4}} =
             call(:list_books, %{author: "Asimov", page_size: 2})

    assert token != ""

    # server streaming
    assert {:ok, stream} = AshGrpc.Client.stream(:e2e_foreign, :watch_books, %{})
    assert stream |> Enum.to_list() |> length() == 5

    # update with update_mask: only the masked field changes, unset fields are left alone
    assert {:ok, updated} =
             call(:update_book, %{
               id: created.id,
               title: "Dune Messiah",
               pages: 1,
               update_mask: %{paths: ["title"]}
             })

    assert updated.title == "Dune Messiah"
    assert updated.pages == 412
    assert updated.author == "Herbert"

    # delete returns google.protobuf.Empty, the record is gone
    assert {:ok, %Google.Protobuf.Empty{}} = call(:delete_book, %{id: created.id})
    assert {:error, %GRPC.RPCError{status: 5}} = call(:get_book, %{id: created.id})
  end

  test "validation errors arrive as INVALID_ARGUMENT with BadRequest details",
       %{out: out, port: port} do
    import_and_connect!(out, port)

    assert {:error, %GRPC.RPCError{status: 3} = error} =
             call(:create_book, %{title: "Short", pages: 0})

    assert [%BadRequest{field_violations: violations}] =
             for(
               %BadRequest{} = detail <- AshGrpc.Error.Details.unpack_all(error.details),
               do: detail
             )

    assert [%{field: "pages", description: description}] = violations
    assert description =~ "1"
  end

  defp page_through(request, acc \\ []) do
    {:ok, %{books: books, next_page_token: token}} = call(:list_books, request)
    acc = acc ++ books

    if token == "", do: acc, else: page_through(Map.put(request, :page_token, token), acc)
  end

  defp titles(books), do: Enum.map(books, & &1.title)
end
