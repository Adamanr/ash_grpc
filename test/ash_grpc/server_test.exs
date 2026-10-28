defmodule AshGrpc.ServerTest do
  # A real AshGrpc.Server (cowboy, random port) called through an AshGrpc.Client.
  use ExUnit.Case, async: false

  alias AshGrpc.Test.Server.{Client, Doc, Endpoint, Item, Note}
  alias AshGrpc.Test.Server.Proto.V1, as: P
  alias Google.Rpc.BadRequest

  @moduletag :capture_log

  setup_all do
    start_supervised!({AshGrpc.Server, endpoint: Endpoint, port: 0})
    port = AshGrpc.Server.port(Endpoint)
    start_supervised!({Client, address: "127.0.0.1:#{port}", map_errors: false, deadline: 5_000})
    %{port: port}
  end

  setup do
    for resource <- [Item, Note, Doc], do: Ash.DataLayer.Ets.stop(resource)
    :ok
  end

  defp create!(attrs) do
    {:ok, item} = Client.call(:create_item, Map.merge(%{name: "item"}, attrs))
    item
  end

  defp status(%GRPC.RPCError{status: status}), do: AshGrpc.Error.Info.code(status)

  defp violations(%GRPC.RPCError{details: details}) do
    for %BadRequest{field_violations: violations} <- AshGrpc.Error.Details.unpack_all(details),
        violation <- violations,
        do: {violation.field, violation.description}
  end

  describe "unary rpcs" do
    test "create returns the record with defaults and calculations" do
      assert {:ok, %P.Item{} = item} =
               Client.call(:create_item, %{name: "Lamp", price: 30, tags: ["home"]})

      assert item.name == "Lamp"
      assert item.price == 30
      assert item.status == :ITEM_STATUS_DRAFT
      assert item.tags == ["home"]
      assert item.label == "Lamp!"
      assert {:ok, _} = Ecto.UUID.cast(item.id)
      assert %Google.Protobuf.Timestamp{} = item.inserted_at
    end

    test "create with wrapped input" do
      assert {:ok, %P.Item{name: "Wrapped", price: 5}} =
               Client.call(:create_item_wrapped, %{item: %{name: "Wrapped", price: 5}})
    end

    test "get by primary key, NOT_FOUND when missing" do
      item = create!(%{name: "Chair"})

      assert {:ok, %P.Item{name: "Chair", label: "Chair!"}} =
               Client.call(:get_item, %{id: item.id})

      assert {:error, error} = Client.call(:get_item, %{id: Ash.UUID.generate()})
      assert status(error) == :not_found
    end

    test "get? action with arguments" do
      create!(%{name: "Desk"})
      assert {:ok, %P.Item{name: "Desk"}} = Client.call(:get_item_by_name, %{name: "Desk"})
      assert {:error, error} = Client.call(:get_item_by_name, %{name: "nope"})
      assert status(error) == :not_found
    end

    test "read_mask selects attributes and loads only listed calculations" do
      item = create!(%{name: "Masked", price: 7, category: "c"})

      assert {:ok, %P.Item{} = masked} =
               Client.call(:get_item, %{id: item.id, read_mask: %{paths: ["name", "label"]}})

      assert masked.id == item.id
      assert masked.name == "Masked"
      assert masked.label == "Masked!"
      assert masked.price == nil
      assert masked.category == nil

      assert {:ok, %P.Item{label: nil, price: 7}} =
               Client.call(:get_item, %{id: item.id, read_mask: %{paths: ["price"]}})

      assert {:error, error} =
               Client.call(:get_item, %{id: item.id, read_mask: %{paths: ["nope"]}})

      assert status(error) == :invalid_argument
      assert [{"read_mask", _}] = violations(error)
    end

    test "update with and without update_mask" do
      item = create!(%{name: "Old", price: 1, category: "keep"})

      assert {:ok, %P.Item{name: "New", price: 1, category: "keep"}} =
               Client.call(:update_item, %{id: item.id, name: "New"})

      # masked fields are set even when absent (category -> nil); unmasked ones are ignored
      assert {:ok, %P.Item{name: "New", price: 2, category: nil}} =
               Client.call(:update_item, %{
                 id: item.id,
                 name: "ignored",
                 price: 2,
                 update_mask: %{paths: ["price", "category"]}
               })

      assert {:error, error} =
               Client.call(:update_item, %{id: item.id, update_mask: %{paths: ["bogus"]}})

      assert status(error) == :invalid_argument

      assert {:error, error} = Client.call(:update_item, %{id: Ash.UUID.generate(), name: "x"})
      assert status(error) == :not_found
    end

    test "destroy returns Empty, or the record with return_destroyed?" do
      item = create!(%{name: "Gone"})
      assert {:ok, %Google.Protobuf.Empty{}} = Client.call(:delete_item, %{id: item.id})
      assert {:error, error} = Client.call(:get_item, %{id: item.id})
      assert status(error) == :not_found

      item = create!(%{name: "Archived"})

      assert {:ok, %P.Item{name: "Archived"}} =
               Client.call(:archive_item, %{id: item.id, reason: "old"})

      assert {:error, error} = Client.call(:delete_item, %{id: item.id})
      assert status(error) == :not_found
    end

    test "generic actions: wrapped scalars, arrays and no return" do
      assert {:ok, %P.EchoResponse{value: "hello"}} = Client.call(:echo, %{message: "hello"})
      assert {:ok, %Google.Protobuf.Empty{}} = Client.call(:noop, %{})

      create!(%{name: "b"})
      create!(%{name: "a"})
      assert {:ok, %P.NamesResponse{value: ["a", "b"]}} = Client.call(:names, %{})
    end
  end

  describe "list" do
    setup do
      items =
        for i <- 1..5 do
          create!(%{
            name: "item-#{i}",
            price: i * 10,
            category: if(rem(i, 2) == 0, do: "even", else: "odd")
          })
        end

      %{items: items}
    end

    test "keyset pagination with opaque tokens and total_size" do
      assert {:ok, %P.ListItemsResponse{items: page1, next_page_token: token, total_size: 5}} =
               Client.call(:list_items, %{page_size: 2, order_by: "price"})

      assert Enum.map(page1, & &1.price) == [10, 20]
      assert token != ""

      assert {:ok, %P.ListItemsResponse{items: page2, next_page_token: token2}} =
               Client.call(:list_items, %{page_size: 2, page_token: token, order_by: "price"})

      assert Enum.map(page2, & &1.price) == [30, 40]

      assert {:ok, %P.ListItemsResponse{items: [%{price: 50}], next_page_token: ""}} =
               Client.call(:list_items, %{page_size: 2, page_token: token2, order_by: "price"})
    end

    test "filter, order_by and arguments" do
      assert {:ok, %P.ListItemsResponse{items: items}} =
               Client.call(:list_items, %{
                 filter: ~s({"price": {"greater_than": 15}}),
                 order_by: "price desc",
                 category: "odd"
               })

      assert Enum.map(items, & &1.price) == [50, 30]
    end

    test "invalid filters and tokens are INVALID_ARGUMENT" do
      assert {:error, error} = Client.call(:list_items, %{filter: "not json"})
      assert status(error) == :invalid_argument
      assert [{"filter", _}] = violations(error)

      assert {:error, error} = Client.call(:list_items, %{filter: ~s({"nope": 1})})
      assert status(error) == :invalid_argument

      assert {:error, error} = Client.call(:list_items, %{page_token: "garbage!"})
      assert status(error) == :invalid_argument
      assert [{"page_token", _}] = violations(error)
    end

    test "offset pagination and actions without pagination" do
      for rpc <- [:list_items_offset, :list_items_plain] do
        {:ok, %{items: first, next_page_token: token}} = Client.call(rpc, %{page_size: 3})
        assert length(first) == 3
        assert token != ""

        {:ok, %{items: rest, next_page_token: ""}} =
          Client.call(rpc, %{page_size: 3, page_token: token})

        assert length(rest) == 2

        assert Enum.sort(Enum.map(first ++ rest, & &1.id)) ==
                 Enum.sort(Enum.map(Ash.read!(Item), & &1.id))
      end
    end
  end

  describe "streaming" do
    test "server stream sends every record" do
      for i <- 1..120, do: Ash.create!(Item, %{name: "s#{i}"})

      assert {:ok, stream} = Client.stream(:watch_items, %{})
      names = Enum.map(stream, & &1.name)
      assert length(names) == 120
      assert "s1" in names and "s120" in names
    end

    test "client stream bulk creates and reports per-item errors" do
      requests = [
        %{name: "a", price: 1},
        %{name: "b", price: -1},
        %{name: "", price: 2},
        %{name: "c"}
      ]

      assert {:ok, %P.ImportItemsResponse{count: 2, errors: errors}} =
               Client.stream(:import_items, requests)

      assert length(errors) == 2
      assert Enum.all?(errors, &(&1.code == GRPC.Status.invalid_argument()))
      assert Ash.read!(Item) |> Enum.map(& &1.name) |> Enum.sort() == ["a", "c"]
    end

    test "bidirectional stream with a custom handler" do
      assert {:ok, stream} = Client.stream(:chat, [%{message: "a"}, %{message: "b"}])

      assert [%P.ChatResponse{value: "re:a"}, %P.ChatResponse{value: "re:b"}] =
               Enum.to_list(stream)
    end

    test "a server stream stops when the deadline expires" do
      parent = self()
      ref = make_ref()

      :telemetry.attach(
        "server-stream-#{inspect(ref)}",
        [:ash_grpc, :server, :rpc, :start],
        fn _, _, %{rpc: "WatchItems"}, _ -> send(parent, {ref, self()}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("server-stream-#{inspect(ref)}") end)

      for i <- 1..2_000, do: Ash.create!(Item, %{name: "s#{i}"})

      result = Client.stream(:watch_items, %{}, deadline: 30)

      case result do
        {:ok, stream} -> assert_raise GRPC.RPCError, fn -> Enum.to_list(stream) end
        {:error, error} -> assert status(error) == :deadline_exceeded
      end

      # on a slow runner the deadline may expire before the handler starts at all; when it did
      # start it must terminate
      receive do
        {^ref, handler} ->
          monitor = Process.monitor(handler)
          assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      after
        500 -> :ok
      end
    end
  end

  describe "errors" do
    test "validation errors are INVALID_ARGUMENT with BadRequest field violations" do
      assert {:error, error} = Client.call(:create_item, %{name: "x", price: -5})
      assert status(error) == :invalid_argument
      assert [{"price", _}] = violations(error)

      assert {:error, error} = Client.call(:create_item, %{name: ""})
      assert status(error) == :invalid_argument
      assert [{"name", "is required"}] = violations(error)
    end

    test "invalid wire values are INVALID_ARGUMENT" do
      assert {:error, error} = Client.call(:get_item, %{id: "not-a-uuid"})
      assert status(error) == :invalid_argument
    end

    test "unexpected exceptions are INTERNAL without leaking the message" do
      assert {:error, error} = Client.call(:boom, %{})
      assert status(error) == :internal
      refute error.message =~ "secret"
    end
  end

  describe "context" do
    test "actor from metadata is used by policies" do
      assert {:error, error} = Client.call(:create_note, %{body: "anonymous"})
      assert status(error) == :permission_denied

      alice = [metadata: %{"authorization" => "Bearer alice"}]
      bob = [metadata: %{"authorization" => "Bearer bob"}]

      assert {:ok, %P.Note{owner_id: "alice"}} = Client.call(:create_note, %{body: "hi"}, alice)
      assert {:ok, %{notes: [%P.Note{body: "hi"}]}} = Client.call(:list_notes, %{}, alice)
      assert {:ok, %{notes: []}} = Client.call(:list_notes, %{}, bob)
      assert {:ok, %{value: "alice"}} = Client.call(:whoami, %{}, alice)
    end

    test "invalid credentials are UNAUTHENTICATED" do
      assert {:error, error} =
               Client.call(:whoami, %{}, metadata: %{"authorization" => "Bearer bad"})

      assert status(error) == :unauthenticated
    end

    test "tenant from x-tenant metadata" do
      a = [metadata: %{"x-tenant" => "org-a"}]
      b = [metadata: %{"x-tenant" => "org-b"}]

      assert {:ok, %P.Doc{org: "org-a"}} = Client.call(:create_doc, %{title: "A"}, a)
      assert {:ok, %{docs: [%P.Doc{title: "A"}]}} = Client.call(:list_docs, %{}, a)
      assert {:ok, %{docs: []}} = Client.call(:list_docs, %{}, b)

      assert {:error, error} = Client.call(:list_docs, %{})
      refute status(error) == :ok
    end

    test "grpc-timeout becomes the action timeout" do
      assert {:error, error} = Client.call(:slow, %{ms: 500}, deadline: 50, retry: false)
      assert status(error) == :deadline_exceeded
      assert {:ok, %{value: "done"}} = Client.call(:slow, %{ms: 1})
    end

    test "the remaining deadline is propagated to AshGrpc.Client calls" do
      parent = self()

      :telemetry.attach(
        "deadline-propagation",
        [:ash_grpc, :server, :rpc, :start],
        fn _, _, %{rpc: "Echo"}, _ ->
          send(parent, {:remaining, AshGrpc.Client.remaining_deadline()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("deadline-propagation") end)

      assert {:ok, _} = Client.call(:echo, %{message: "x"}, deadline: 2_000)
      assert_receive {:remaining, remaining}
      assert remaining > 0 and remaining <= 2_000
    end
  end

  describe "logger interceptor" do
    test "logs the rpc path and status" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Client.call(:get_item, %{id: Ash.UUID.generate()})
          Client.call(:noop, %{})
        end)

      assert log =~ "GRPC /ashgrpc.test.shop.v1.ShopService/GetItem -> NOT_FOUND"
      assert log =~ "GRPC /ashgrpc.test.shop.v1.ShopService/Noop -> OK"
    end
  end

  describe "telemetry" do
    test "start and stop events carry the rpc and status" do
      parent = self()

      :telemetry.attach_many(
        "server-telemetry",
        [[:ash_grpc, :server, :rpc, :start], [:ash_grpc, :server, :rpc, :stop]],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("server-telemetry") end)

      Client.call(:get_item, %{id: Ash.UUID.generate()})

      assert_receive {[:ash_grpc, :server, :rpc, :start], _, %{rpc: "GetItem", kind: :get}}

      assert_receive {[:ash_grpc, :server, :rpc, :stop], %{duration: _},
                      %{rpc: "GetItem", status: :not_found, resource: Item}}
    end
  end

  describe "health" do
    test "Check reports SERVING for the server and its services" do
      for service <- ["", "ashgrpc.test.shop.v1.ShopService"] do
        assert {:ok, %{status: :SERVING}} = Client.call(:check, %{service: service})
      end

      assert {:error, error} = Client.call(:check, %{service: "unknown.Service"})
      assert status(error) == :not_found
    end

    test "Watch streams status changes" do
      service = "ashgrpc.test.shop.v1.DocsService"
      assert {:ok, stream} = Client.stream(:watch, %{service: service}, deadline: 2_000)

      task =
        Task.async(fn -> stream |> Stream.take(2) |> Enum.map(& &1.status) end)

      Process.sleep(100)
      AshGrpc.Server.Health.set_status(Endpoint, service, :not_serving)
      assert Task.await(task) == [:SERVING, :NOT_SERVING]
    after
      AshGrpc.Server.Health.set_status(Endpoint, "ashgrpc.test.shop.v1.DocsService", :serving)
    end
  end

  describe "reflection" do
    test "lists services and serves descriptors" do
      alias Grpc.Reflection.V1.ServerReflectionRequest, as: Req

      assert {:ok, stream} =
               Client.stream(:server_reflection_info, [
                 %Req{message_request: {:list_services, ""}},
                 %Req{
                   message_request: {:file_containing_symbol, "ashgrpc.test.shop.v1.ShopService"}
                 }
               ])

      [list, file] = Enum.to_list(stream)

      {:list_services_response, %{service: services}} = list.message_response
      names = Enum.map(services, & &1.name)
      assert "ashgrpc.test.shop.v1.ShopService" in names
      assert "grpc.health.v1.Health" in names

      {:file_descriptor_response, %{file_descriptor_proto: [proto | _]}} = file.message_response
      descriptor = Google.Protobuf.FileDescriptorProto.decode(proto)
      assert [%{name: "ShopService", method: methods}] = descriptor.service
      assert Enum.any?(methods, &(&1.name == "GetItem"))
    end
  end

  describe "endpoint" do
    test "schema/0 and generated server modules" do
      assert %AshGrpc.Proto.IR.Schema{files: [file]} = Endpoint.schema()
      assert file.package == "ashgrpc.test.shop.v1"
      assert Code.ensure_loaded?(Endpoint.Servers.ShopService)
      assert Endpoint.Servers.ShopService in Endpoint.__meta__(:servers)
      assert AshGrpc.Server.Health.Server in Endpoint.__meta__(:servers)
    end
  end
end
