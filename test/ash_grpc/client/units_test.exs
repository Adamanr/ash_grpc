defmodule AshGrpc.Client.UnitsTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Client.{Codec, Config, Errors, Request, Retry, RpcTable}

  alias AshGrpc.Test.Client.{
    EchoClient,
    EchoRequest,
    EchoResponse,
    EchoService,
    GreeterService,
    Inner
  }

  describe "Config" do
    test "merges use opts, app env, start opts and init/1; validates" do
      assert {:ok, %Config{} = config} =
               Config.build(AshGrpc.Test.Client.OtherClient, [services: [EchoService.Service]],
                 address: "localhost:1",
                 retry: [max_attempts: 5],
                 compression: :gzip,
                 max_message_size: 10,
                 max_receive_message_size: 20
               )

      assert config.name == AshGrpc.Test.Client.OtherClient
      # from init/1
      assert config.deadline == 3_000

      assert config.retry == %{
               max_attempts: 5,
               backoff: {:exponential, 50, 2_000},
               jitter: true,
               on: [:unavailable]
             }

      assert config.compression == GRPC.Compressor.Gzip
      assert config.max_send_message_size == 10
      assert config.max_receive_message_size == 20
      assert config.tls == false
    end

    test "tls options become credentials" do
      assert {:ok, %Config{tls: %GRPC.Credential{ssl: ssl}}} =
               Config.build(nil, [],
                 name: :c,
                 services: [],
                 address: "h:1",
                 tls: [cacertfile: "ca.pem", certfile: "c.pem", keyfile: "k.pem"]
               )

      assert ssl[:cacertfile] == "ca.pem"
      assert ssl[:certfile] == "c.pem"
      assert ssl[:verify] == :verify_peer

      assert {:ok, %Config{tls: %GRPC.Credential{ssl: ssl}}} =
               Config.build(nil, [], name: :c, services: [], address: "h:1", tls: true)

      assert is_list(ssl[:cacerts])
    end

    test "invalid configuration" do
      assert {:error, %ArgumentError{message: message}} =
               Config.build(nil, [], services: [], address: "h:1")

      assert message =~ ":name"

      assert {:error, %ArgumentError{message: message}} =
               Config.build(nil, [], name: :c, services: [])

      assert message =~ ":address"

      assert {:error, %Spark.Options.ValidationError{}} =
               Config.build(nil, [], name: :c, services: [], address: "h:1", pool_size: 0)

      assert {:error, %Spark.Options.ValidationError{}} =
               Config.build(nil, [],
                 name: :c,
                 services: [],
                 address: "h:1",
                 retry: [on: [:not_a_status]]
               )

      assert {:error, %Spark.Options.ValidationError{}} =
               Config.build(nil, [], name: :c, services: [], address: "h:1", metadata: 42)

      assert {:error, _} = AshGrpc.Client.start_link(name: :bad, services: [])
    end
  end

  describe "RpcTable" do
    test "compile-time table of a client module" do
      table = EchoClient.__rpc_table__()

      assert {:ok, %RpcTable.Entry{name: :GetEcho, idempotent?: true}} =
               RpcTable.fetch(table, :get_echo)

      assert {:ok, %RpcTable.Entry{name: :Flaky, idempotent?: true}} =
               RpcTable.fetch(table, "Flaky")

      assert {:ok, %RpcTable.Entry{name: :Mutate, idempotent?: false}} =
               RpcTable.fetch(table, :Mutate)

      assert {:ok, %RpcTable.Entry{grpc_type: :bidirectional_stream}} =
               RpcTable.fetch(table, {EchoService.Service, :chat})

      assert length(RpcTable.entries(table)) == 7
    end

    test "ambiguous names" do
      table = RpcTable.build([EchoService.Service, GreeterService.Service])
      assert {:error, %ArgumentError{message: message}} = RpcTable.fetch(table, :echo)
      assert message =~ "ambiguous"

      assert {:ok, %{service: GreeterService.Service}} =
               RpcTable.fetch(table, {GreeterService.Service, :echo})

      assert {:ok, %{service: EchoService.Service}} =
               RpcTable.fetch(table, "/ash_grpc.test.v1.EchoService/Echo")
    end

    test "rejects non-service modules" do
      assert_raise ArgumentError, ~r/not a GRPC.Service/, fn -> RpcTable.build([String]) end
    end
  end

  describe "Retry" do
    @policy %{max_attempts: 3, backoff: {:exponential, 10, 25}, jitter: false, on: [:unavailable]}

    test "delay grows exponentially and is capped" do
      assert Enum.map(1..4, &Retry.delay(@policy, &1)) == [10, 20, 25, 25]
      assert Retry.delay(%{@policy | jitter: true}, 2) in 0..20
    end

    test "retry? only for idempotent rpcs, listed statuses and remaining attempts" do
      assert Retry.retry?(@policy, true, 14, 1)
      refute Retry.retry?(@policy, false, 14, 1)
      refute Retry.retry?(@policy, true, 5, 1)
      refute Retry.retry?(@policy, true, 14, 3)
      refute Retry.retry?(false, true, 14, 1)
    end

    test "run stops when the backoff would cross the deadline" do
      deadline_at = System.monotonic_time(:millisecond) + 5
      policy = %{@policy | backoff: {:exponential, 1_000, 1_000}}
      unavailable = {:error, Errors.rpc_error(:unavailable, "down")}

      assert {^unavailable, 1} = Retry.run(policy, true, deadline_at, fn _ -> unavailable end)
    end

    test "merge" do
      assert Retry.merge(@policy, false) == false
      assert Retry.merge(@policy, nil) == @policy
      assert %{max_attempts: 7, on: [:unavailable]} = Retry.merge(false, max_attempts: 7)
    end
  end

  describe "Errors" do
    test "normalizes transport failures to UNAVAILABLE" do
      assert %GRPC.RPCError{status: 14} =
               Errors.normalize(%GRPC.RPCError{
                 status: 2,
                 message:
                   "error occurred while receiving data: {:error, \"the connection is closed\"}"
               })

      assert %GRPC.RPCError{status: 14} = Errors.normalize({:exit, :noproc})
      assert %GRPC.RPCError{status: 14} = Errors.normalize(:no_connection)

      assert %GRPC.RPCError{status: 2} =
               Errors.normalize(%GRPC.RPCError{status: 2, message: "boom"})

      assert %GRPC.RPCError{status: 13} = Errors.normalize(%RuntimeError{message: "x"})
    end

    test "status names" do
      assert Errors.status_name(14) == :unavailable
      assert Errors.status_code(:deadline_exceeded) == 4
    end

    test "from_rpc_error delegates to AshGrpc.Error.from_rpc_error/2 only when it exists" do
      error = Errors.rpc_error(:not_found, "missing")

      if function_exported?(AshGrpc.Error, :from_rpc_error, 2) do
        assert %{__exception__: true} = Errors.from_rpc_error(error, [])
      else
        assert Errors.from_rpc_error(error, []) == error
      end
    end
  end

  describe "Request" do
    test "builds nested structs from maps with atom or string keys" do
      assert {:ok,
              %EchoRequest{
                message: "m",
                inner: %Inner{label: "x"},
                items: [%Inner{label: "a"}, %Inner{tags: ["t"]}]
              }} =
               Request.build(EchoRequest, %{
                 "message" => "m",
                 inner: %{label: "x"},
                 items: [%{label: "a"}, %Inner{tags: ["t"]}]
               })

      assert {:ok, %EchoRequest{message: "kw"}} = Request.build(EchoRequest, message: "kw")
    end

    test "map fields" do
      assert {:ok, %EchoResponse{metadata: %{"a" => "b"}}} =
               Request.build(EchoResponse, %{metadata: %{"a" => "b"}})
    end

    test "errors" do
      assert {:error, %ArgumentError{}} = Request.build(EchoRequest, %{"nope" => 1})
      assert {:error, %ArgumentError{}} = Request.build(EchoRequest, %{nope: 1})
      assert {:error, %ArgumentError{}} = Request.build(EchoRequest, %EchoResponse{})
      assert {:error, %ArgumentError{}} = Request.build(EchoRequest, 42)
    end
  end

  describe "Codec" do
    test "defers decoding and enforces the receive limit" do
      binary = Protobuf.encode(%EchoResponse{message: "hello"})
      raw = Codec.decode(binary, EchoResponse)

      assert {:ok, %EchoResponse{message: "hello"}} = Codec.finalize(raw, nil)
      assert {:error, %GRPC.RPCError{status: 8}} = Codec.finalize(raw, 2)

      assert {:error, %GRPC.RPCError{status: 13}} =
               Codec.finalize(%{raw | binary: <<255, 255>>}, nil)

      assert {:ok, :decoded} = Codec.finalize(:decoded, 1)
      assert Codec.name() == "proto"
    end
  end

  describe "deadline propagation" do
    test "put_deadline/1 and remaining_deadline/0" do
      assert AshGrpc.Client.remaining_deadline() == nil
      :ok = AshGrpc.Client.put_deadline(1_000)
      assert AshGrpc.Client.remaining_deadline() in 900..1_000
      :ok = AshGrpc.Client.put_deadline(nil)
      assert AshGrpc.Client.remaining_deadline() == nil
    end
  end
end
