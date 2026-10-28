defmodule AshGrpc.ClientReconnectTest do
  use ExUnit.Case, async: false

  alias AshGrpc.Test.Client.{EchoResponse, EchoService, EndpointB, Server}

  @moduletag :capture_log

  test "reconnects after the server restarts; propagated deadline applies" do
    port = Server.start(EndpointB)
    on_exit(fn -> Server.stop(EndpointB) end)

    start_supervised!({
      AshGrpc.Client,
      # The retry budget (< 1 s) is deliberately shorter than the Mint adapter's own re-dial
      # backoff (>= 1 s): bridging the restart must not depend on the adapter re-dialing.
      name: :reconnect_client,
      services: [EchoService.Service],
      address: "127.0.0.1:#{port}",
      map_errors: false,
      connect_timeout: 200,
      retry: [max_attempts: 10, backoff: {:exponential, 20, 100}],
      idempotent: [:echo]
    })

    assert {:ok, %EchoResponse{server: "b"}} =
             AshGrpc.Client.call(:reconnect_client, :echo, %{key: "r1"})

    Server.stop(EndpointB)

    assert {:error, %GRPC.RPCError{status: 14}} =
             AshGrpc.Client.call(:reconnect_client, :echo, %{key: "r2"}, retry: false)

    {:ok, _pid, ^port} = Server.start_endpoint(EndpointB, port)

    # The failed r2 call reset the pooled connection; retries (with backoff) bridge the window
    # until the fresh connection is established.
    assert {:ok, %EchoResponse{server: "b"}} =
             AshGrpc.Client.call(:reconnect_client, :echo, %{key: "r3"}, deadline: 10_000)

    AshGrpc.Client.put_deadline(50)

    assert {:error, %GRPC.RPCError{status: 4}} =
             AshGrpc.Client.call(:reconnect_client, :echo, %{key: "r4", delay_ms: 300},
               deadline: 10_000
             )
  after
    AshGrpc.Client.put_deadline(nil)
  end
end
