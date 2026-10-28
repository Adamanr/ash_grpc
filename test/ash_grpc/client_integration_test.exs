defmodule AshGrpc.ClientIntegrationTest do
  # Talks to real GRPC.Server instances on random local ports.
  use ExUnit.Case, async: false

  alias AshGrpc.Test.Client.{
    EchoClient,
    EchoRequest,
    EchoResponse,
    EchoService,
    Inner,
    OtherClient
  }

  @moduletag :capture_log

  setup_all do
    port_a = AshGrpc.Test.Client.Server.start(AshGrpc.Test.Client.EndpointA)
    port_b = AshGrpc.Test.Client.Server.start(AshGrpc.Test.Client.EndpointB)

    on_exit(fn ->
      AshGrpc.Test.Client.Server.stop(AshGrpc.Test.Client.EndpointA)
      AshGrpc.Test.Client.Server.stop(AshGrpc.Test.Client.EndpointB)
    end)

    %{port_a: port_a, port_b: port_b}
  end

  setup %{port_a: port_a, port_b: port_b} do
    Application.put_env(:ash_grpc, EchoClient,
      address: "127.0.0.1:#{port_a}",
      map_errors: false,
      metadata: fn ctx ->
        actor = ctx.opts[:actor]
        %{"x-static" => "yes", "x-actor" => (actor && actor.id) || "none"}
      end
    )

    on_exit(fn -> Application.delete_env(:ash_grpc, EchoClient) end)

    start_supervised!(EchoClient)
    start_supervised!({OtherClient, address: "localhost:#{port_b}", map_errors: false})
    :ok
  end

  defp key, do: "key-#{System.unique_integer([:positive])}"

  describe "unary" do
    test "struct and map requests, nested maps become structs" do
      assert {:ok, %EchoResponse{message: "hi", server: "a"}} =
               EchoClient.call(:echo, %EchoRequest{message: "hi", key: key()})

      assert {:ok, %EchoResponse{message: "map", inner: %Inner{label: "l", tags: ["t"]}}} =
               EchoClient.call(:echo, %{
                 message: "map",
                 key: key(),
                 inner: %{"label" => "l", tags: ["t"]}
               })
    end

    test "every rpc name form resolves" do
      for rpc <- [
            :echo,
            :Echo,
            "Echo",
            "echo",
            {EchoService.Service, :echo},
            "/ash_grpc.test.v1.EchoService/Echo",
            "ash_grpc.test.v1.EchoService/Echo"
          ] do
        assert {:ok, %EchoResponse{message: "n"}} =
                 EchoClient.call(rpc, %{message: "n", key: key()})
      end
    end

    test "programming errors are returned as ArgumentError" do
      assert {:error, %ArgumentError{message: "unknown rpc :nope"}} = EchoClient.call(:nope, %{})
      assert {:error, %ArgumentError{}} = EchoClient.call(:echo, %{unknown_field: 1})
      assert {:error, %ArgumentError{message: msg}} = EchoClient.call(:count, %{})
      assert msg =~ "use stream/3"
    end

    test "deadline exceeded" do
      assert {:error, %GRPC.RPCError{status: 4}} =
               EchoClient.call(:echo, %{delay_ms: 500, key: key()}, deadline: 100)
    end

    test "metadata: client function (with call opts) merged with per-call metadata" do
      assert {:ok, %EchoResponse{metadata: metadata}} =
               EchoClient.call(:echo, %{key: key()},
                 actor: %{id: "user-1"},
                 metadata: %{"x-call" => "1", "x-static" => "overridden"}
               )

      assert metadata["x-actor"] == "user-1"
      assert metadata["x-call"] == "1"
      assert metadata["x-static"] == "overridden"
    end

    test "gzip compression" do
      assert {:ok, %EchoResponse{message: "zip"}} =
               EchoClient.call(:echo, %{message: "zip", key: key()}, compression: :gzip)
    end

    test "return_headers" do
      assert {:ok, %EchoResponse{}, %{headers: headers}} =
               EchoClient.call(:echo, %{key: key()}, return_headers: true)

      assert is_map(headers)
    end
  end

  describe "retries" do
    test "idempotent rpc (from the service descriptor) is retried on UNAVAILABLE" do
      k = key()

      assert {:ok, %EchoResponse{attempt: 3}} =
               EchoClient.call(:flaky, %{key: k, fail_times: 2},
                 retry: [max_attempts: 3, backoff: {:exponential, 5, 20}]
               )
    end

    test "gives up after max_attempts" do
      k = key()

      assert {:error, %GRPC.RPCError{status: 14}} =
               EchoClient.call(:get_echo, %{key: k, fail_times: 5},
                 retry: [max_attempts: 2, backoff: {:exponential, 5, 20}]
               )

      assert AshGrpc.Test.Client.EchoImpl.attempts(k) == 2
    end

    test "non-idempotent rpc is not retried unless marked idempotent" do
      k = key()
      retry = [max_attempts: 3, backoff: {:exponential, 5, 20}]

      assert {:error, %GRPC.RPCError{status: 14}} =
               EchoClient.call(:mutate, %{key: k, fail_times: 1}, retry: retry)

      assert AshGrpc.Test.Client.EchoImpl.attempts(k) == 1

      assert {:ok, %EchoResponse{attempt: 2}} =
               EchoClient.call(:mutate, %{key: k, fail_times: 1}, retry: retry, idempotent: true)
    end

    test "client :idempotent option and status filter", %{port_a: port} do
      start_supervised!(
        {AshGrpc.Client,
         name: :idempotent_client,
         services: [EchoService.Service],
         address: "127.0.0.1:#{port}",
         idempotent: [:mutate],
         map_errors: false,
         retry: [max_attempts: 3, backoff: {:exponential, 5, 20}]}
      )

      assert {:ok, %EchoResponse{attempt: 2}} =
               AshGrpc.Client.call(:idempotent_client, :mutate, %{key: key(), fail_times: 1})

      # NOT_FOUND (5) is not in `on: [:unavailable]`
      k = key()

      assert {:error, %GRPC.RPCError{status: 5}} =
               AshGrpc.Client.call(:idempotent_client, :mutate, %{
                 key: k,
                 fail_times: 1,
                 fail_status: 5
               })

      assert AshGrpc.Test.Client.EchoImpl.attempts(k) == 1
    end
  end

  describe "streaming" do
    test "server streaming" do
      assert {:ok, stream} = EchoClient.stream(:count, %{message: "n", count: 3})
      assert Enum.map(stream, & &1.message) == ["n-1", "n-2", "n-3"]
    end

    test "client streaming" do
      requests = [%EchoRequest{message: "a"}, %{message: "b"}, %{message: "c"}]
      assert {:ok, %EchoResponse{message: "a,b,c"}} = EchoClient.stream(:collect, requests)
    end

    test "bidirectional streaming" do
      assert {:ok, stream} = EchoClient.stream(:chat, Stream.map(1..3, &%{message: "#{&1}"}))
      assert Enum.map(stream, & &1.message) == ["re:1", "re:2", "re:3"]
    end
  end

  describe "multiple clients" do
    test "two clients talk to two servers at the same time" do
      tasks =
        for i <- 1..20 do
          client = if rem(i, 2) == 0, do: EchoClient, else: OtherClient
          Task.async(fn -> {client, client.call(:echo, %{message: "#{i}", key: key()})} end)
        end

      for {client, {:ok, response}} <- Task.await_many(tasks) do
        assert response.server == if(client == EchoClient, do: "a", else: "b")
      end

      assert OtherClient.config().deadline == 3_000
      assert EchoClient.config().deadline == 10_000
    end

    test "dynamic client with pool and lazy connect", %{port_b: port} do
      start_supervised!(
        {AshGrpc.Client,
         name: :dynamic_client,
         services: [EchoService.Service],
         address: "127.0.0.1:#{port}",
         pool_size: 3,
         connect: :lazy}
      )

      assert %{status: :idle} = AshGrpc.Client.health(:dynamic_client)

      for _ <- 1..6 do
        assert {:ok, %EchoResponse{server: "b"}} =
                 AshGrpc.Client.call(:dynamic_client, :echo, %{key: key()})
      end

      assert %{status: :ready, connections: connections} = AshGrpc.Client.health(:dynamic_client)
      assert length(connections) == 3
      assert Enum.all?(connections, &match?({_, :ready}, &1))
      assert {:ok, %GRPC.Channel{}} = AshGrpc.Client.channel(:dynamic_client)
    end

    test "channel/1 works with plain GRPC stubs" do
      assert {:ok, channel} = EchoClient.channel()
      assert %{status: :ready} = EchoClient.health()

      assert {:ok, %EchoResponse{message: "raw"}} =
               GRPC.Stub.call(
                 EchoService.Service,
                 hd(EchoService.Service.__rpc_calls__()),
                 %GRPC.Client.Stream{
                   channel: channel,
                   service_name: "ash_grpc.test.v1.EchoService",
                   method_name: "Echo",
                   grpc_type: :unary,
                   path: "/ash_grpc.test.v1.EchoService/Echo",
                   rpc: hd(EchoService.Service.__rpc_calls__()),
                   server_stream: false
                 },
                 %EchoRequest{message: "raw", key: key()},
                 []
               )
    end
  end

  describe "failures" do
    test "unreachable server is UNAVAILABLE" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      start_supervised!(
        {AshGrpc.Client,
         name: :unreachable_client,
         services: [EchoService.Service],
         address: "127.0.0.1:#{port}",
         connect_timeout: 100,
         map_errors: false}
      )

      assert {:error, %GRPC.RPCError{status: 14}} =
               AshGrpc.Client.call(:unreachable_client, :echo, %{})

      assert %{status: :connecting} = AshGrpc.Client.health(:unreachable_client)
    end

    test "client that is not started" do
      assert {:error, %GRPC.RPCError{status: 14, message: message}} =
               AshGrpc.Client.call(:not_started_client, :echo, %{})

      assert message =~ "not started"
    end

    test "message size limits", %{port_a: port} do
      start_supervised!(
        {AshGrpc.Client,
         name: :limited_client,
         services: [EchoService.Service],
         address: "127.0.0.1:#{port}",
         max_send_message_size: 100,
         max_receive_message_size: 50,
         map_errors: false}
      )

      big = String.duplicate("x", 200)

      assert {:error, %GRPC.RPCError{status: 8, message: "request message larger" <> _}} =
               AshGrpc.Client.call(:limited_client, :echo, %{message: big})

      assert {:error, %GRPC.RPCError{status: 8, message: "received message larger" <> _}} =
               AshGrpc.Client.call(:limited_client, :echo, %{
                 message: String.duplicate("y", 60),
                 key: key()
               })

      assert {:ok, %EchoResponse{message: "ok"}} =
               AshGrpc.Client.call(:limited_client, :echo, %{message: "ok", key: "k"})

      assert {:ok, stream} =
               AshGrpc.Client.stream(:limited_client, :count, %{message: "s", count: 2})

      assert Enum.map(stream, & &1.message) == ["s-1", "s-2"]
    end
  end

  describe "telemetry" do
    test "emits start/stop spans with client/service/rpc/status" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "client-test-#{inspect(ref)}",
        [[:ash_grpc, :client, :rpc, :start], [:ash_grpc, :client, :rpc, :stop]],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("client-test-#{inspect(ref)}") end)

      EchoClient.call(:flaky, %{key: key(), fail_times: 1},
        retry: [max_attempts: 2, backoff: {:exponential, 5, 10}]
      )

      assert_receive {^ref, [:ash_grpc, :client, :rpc, :start], %{system_time: _}, start_meta}
      assert start_meta.client == EchoClient
      assert start_meta.service == EchoService.Service
      assert start_meta.rpc == :Flaky

      assert_receive {^ref, [:ash_grpc, :client, :rpc, :stop], %{duration: _}, stop_meta}
      assert stop_meta.status == :ok
      assert stop_meta.attempts == 2

      EchoClient.call(:echo, %{delay_ms: 300, key: key()}, deadline: 50)

      assert_receive {^ref, [:ash_grpc, :client, :rpc, :stop], _, %{status: :deadline_exceeded}},
                     1_000
    end
  end
end
