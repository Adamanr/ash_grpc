defmodule AshGrpc.Test.Client.Inner do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :label, 1, type: :string
  field :tags, 2, repeated: true, type: :string
end

defmodule AshGrpc.Test.Client.EchoRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :message, 1, type: :string
  field :delay_ms, 2, type: :int32, json_name: "delayMs"
  field :fail_times, 3, type: :int32, json_name: "failTimes"
  field :key, 4, type: :string
  field :count, 5, type: :int32
  field :inner, 6, type: AshGrpc.Test.Client.Inner
  field :items, 7, repeated: true, type: AshGrpc.Test.Client.Inner
  field :fail_status, 8, type: :int32, json_name: "failStatus"
end

defmodule AshGrpc.Test.Client.EchoResponse.MetadataEntry do
  @moduledoc false
  use Protobuf, map: true, syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule AshGrpc.Test.Client.EchoResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :message, 1, type: :string
  field :server, 2, type: :string

  field :metadata, 3,
    repeated: true,
    type: AshGrpc.Test.Client.EchoResponse.MetadataEntry,
    map: true

  field :attempt, 4, type: :int32
  field :inner, 5, type: AshGrpc.Test.Client.Inner
end

defmodule AshGrpc.Test.Client.EchoService.Service do
  @moduledoc false
  use GRPC.Service, name: "ash_grpc.test.v1.EchoService"

  alias AshGrpc.Test.Client.{EchoRequest, EchoResponse}

  rpc(:Echo, EchoRequest, EchoResponse)
  rpc(:GetEcho, EchoRequest, EchoResponse, %{idempotency_level: :no_side_effects})
  rpc(:Flaky, EchoRequest, EchoResponse, %{idempotency_level: :idempotent})
  rpc(:Mutate, EchoRequest, EchoResponse)
  rpc(:Count, EchoRequest, stream(EchoResponse))
  rpc(:Collect, stream(EchoRequest), EchoResponse)
  rpc(:Chat, stream(EchoRequest), stream(EchoResponse))
end

defmodule AshGrpc.Test.Client.GreeterService.Service do
  @moduledoc false
  # A second service that also defines `Echo`, to test ambiguous rpc names.
  use GRPC.Service, name: "ash_grpc.test.v1.GreeterService"

  alias AshGrpc.Test.Client.{EchoRequest, EchoResponse}

  rpc(:Echo, EchoRequest, EchoResponse)
  rpc(:SayHello, EchoRequest, EchoResponse)
end

defmodule AshGrpc.Test.Client.EchoImpl do
  @moduledoc false
  # Shared implementation of the test servers. `server` identifies which server answered.

  alias AshGrpc.Test.Client.EchoResponse

  @table :ash_grpc_client_test_attempts

  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      spawn(fn ->
        :ets.new(@table, [:named_table, :public, :set])
        send(parent, :table_ready)
        Process.sleep(:infinity)
      end)

      receive do
        :table_ready -> :ok
      end
    end

    :ok
  end

  def attempts(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  def echo(server, request, stream) do
    if request.delay_ms > 0, do: Process.sleep(request.delay_ms)

    attempt = :ets.update_counter(@table, request.key, 1, {request.key, 0})

    if attempt <= request.fail_times do
      status =
        if request.fail_status > 0, do: request.fail_status, else: GRPC.Status.unavailable()

      raise GRPC.RPCError, status: status, message: "failing attempt #{attempt}"
    end

    %EchoResponse{
      message: request.message,
      server: server,
      attempt: attempt,
      inner: request.inner,
      metadata:
        stream
        |> GRPC.Stream.get_headers()
        |> Map.filter(fn {k, _} -> String.starts_with?(k, "x-") end)
    }
  end

  def count(server, request, stream) do
    for i <- 1..request.count//1 do
      GRPC.Server.send_reply(stream, %EchoResponse{
        message: "#{request.message}-#{i}",
        server: server
      })
    end

    stream
  end

  def collect(server, requests, _stream) do
    messages = Enum.map(requests, & &1.message)
    %EchoResponse{message: Enum.join(messages, ","), server: server}
  end

  def chat(server, requests, stream) do
    Enum.each(requests, fn request ->
      GRPC.Server.send_reply(stream, %EchoResponse{
        message: "re:" <> request.message,
        server: server
      })
    end)

    stream
  end
end

for {mod, server} <- [
      {AshGrpc.Test.Client.EchoServerA, "a"},
      {AshGrpc.Test.Client.EchoServerB, "b"}
    ] do
  defmodule mod do
    @moduledoc false
    use GRPC.Server,
      service: AshGrpc.Test.Client.EchoService.Service,
      compressors: [GRPC.Compressor.Gzip]

    alias AshGrpc.Test.Client.EchoImpl

    @server server

    def echo(request, stream), do: EchoImpl.echo(@server, request, stream)
    def get_echo(request, stream), do: EchoImpl.echo(@server, request, stream)
    def flaky(request, stream), do: EchoImpl.echo(@server, request, stream)
    def mutate(request, stream), do: EchoImpl.echo(@server, request, stream)
    def count(request, stream), do: EchoImpl.count(@server, request, stream)
    def collect(requests, stream), do: EchoImpl.collect(@server, requests, stream)
    def chat(requests, stream), do: EchoImpl.chat(@server, requests, stream)
  end
end

# Separate endpoints: without an endpoint, grpc_server keys the cowboy dispatch table on `nil`,
# so two servers started side by side would share their routes.
defmodule AshGrpc.Test.Client.EndpointA do
  @moduledoc false
  use GRPC.Endpoint
  run AshGrpc.Test.Client.EchoServerA
end

defmodule AshGrpc.Test.Client.EndpointB do
  @moduledoc false
  use GRPC.Endpoint
  run AshGrpc.Test.Client.EchoServerB
end

defmodule AshGrpc.Test.Client.Server do
  @moduledoc false
  # Starts a real GRPC.Server endpoint on a random port.

  def start(endpoint) do
    AshGrpc.Test.Client.EchoImpl.ensure_table()
    {:ok, _pid, port} = start_endpoint(endpoint, 0)
    port
  end

  def start_endpoint(endpoint, port) do
    GRPC.Server.start_endpoint(endpoint, port, exception_log_filter: {__MODULE__, :log?})
  end

  # Expected server-side failures (deadline, injected errors) would only add noise.
  def log?(_exception), do: false

  def stop(endpoint), do: GRPC.Server.stop_endpoint(endpoint)
end

defmodule AshGrpc.Test.Client.EchoClient do
  @moduledoc false
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [AshGrpc.Test.Client.EchoService.Service]
end

defmodule AshGrpc.Test.Client.OtherClient do
  @moduledoc false
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [AshGrpc.Test.Client.EchoService.Service]

  @impl AshGrpc.Client
  def init(config) do
    {:ok, Keyword.put_new(config, :deadline, 3_000)}
  end
end

defmodule AshGrpc.Test.Client.SandboxClient do
  @moduledoc false
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [
      AshGrpc.Test.Client.EchoService.Service,
      AshGrpc.Test.Client.GreeterService.Service
    ],
    sandbox: true
end
