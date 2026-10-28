defmodule AshGrpc.Client.SandboxTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Client.Sandbox
  alias AshGrpc.Test.Client.{EchoRequest, EchoResponse, GreeterService, SandboxClient}

  setup_all do
    start_supervised!({SandboxClient, map_errors: false})
    :ok
  end

  # The client is started once for the module; tests below run concurrently against it,
  # each with its own expectations.
  setup :verify_on_exit!

  defp verify_on_exit!(context), do: Sandbox.verify_on_exit!(context)

  test "expectations answer unary calls and are consumed in order" do
    Sandbox.expect(SandboxClient, :mutate, fn %EchoRequest{message: m} ->
      {:ok, %EchoResponse{message: "first " <> m}}
    end)

    Sandbox.expect(SandboxClient, "Mutate", fn req, %{metadata: metadata, deadline: deadline} ->
      assert metadata["x-trace"] == "t1"
      assert deadline <= 1_000
      %EchoResponse{message: "second " <> req.message}
    end)

    assert {:ok, %EchoResponse{message: "first a"}} = SandboxClient.call(:mutate, %{message: "a"})

    assert {:ok, %EchoResponse{message: "second b"}} =
             SandboxClient.call(:mutate, %{message: "b"},
               metadata: %{"x-trace" => "t1"},
               deadline: 1_000
             )
  end

  test "errors, retries and stubs" do
    Sandbox.expect(SandboxClient, :get_echo, 2, fn _ -> {:error, :unavailable} end)
    Sandbox.stub(SandboxClient, :get_echo, fn _ -> {:ok, %EchoResponse{message: "stub"}} end)

    assert {:ok, %EchoResponse{message: "stub"}} =
             SandboxClient.call(:get_echo, %{},
               retry: [max_attempts: 3, backoff: {:exponential, 1, 2}]
             )

    Sandbox.expect(SandboxClient, :get_echo, fn _ -> {:error, {:not_found, "nope"}} end)

    assert {:error, %GRPC.RPCError{status: 5, message: "nope"}} =
             SandboxClient.call(:get_echo, %{}, retry: [max_attempts: 3])
  end

  test "streams" do
    Sandbox.expect(SandboxClient, :count, fn %{count: n} ->
      {:ok, Enum.map(1..n, &%EchoResponse{message: "#{&1}"})}
    end)

    Sandbox.expect(SandboxClient, :collect, fn requests ->
      %EchoResponse{message: Enum.map_join(requests, ",", & &1.message)}
    end)

    Sandbox.expect(SandboxClient, :chat, fn requests ->
      Enum.map(requests, &%EchoResponse{message: "re:" <> &1.message})
    end)

    assert {:ok, stream} = SandboxClient.stream(:count, %{count: 2})
    assert Enum.map(stream, & &1.message) == ["1", "2"]

    assert {:ok, %EchoResponse{message: "a,b"}} =
             SandboxClient.stream(:collect, [%{message: "a"}, %{message: "b"}])

    assert {:ok, stream} = SandboxClient.stream(:chat, [%{message: "x"}])
    assert Enum.map(stream, & &1.message) == ["re:x"]
  end

  test "processes started from the test see its expectations ($callers); others need allow/2" do
    Sandbox.expect(SandboxClient, :get_echo, 2, fn _ -> %EchoResponse{message: "task"} end)

    assert {:ok, %EchoResponse{message: "task"}} =
             Task.async(fn -> SandboxClient.call(:get_echo, %{}) end) |> Task.await()

    test_pid = self()

    pid =
      spawn(fn ->
        receive do
          :go -> send(test_pid, {:result, SandboxClient.call(:get_echo, %{})})
        end
      end)

    Sandbox.allow(self(), pid)
    send(pid, :go)
    assert_receive {:result, {:ok, %EchoResponse{message: "task"}}}
  end

  test "unexpected calls raise" do
    assert_raise Sandbox.UnexpectedCallError, ~r/unexpected call/, fn ->
      SandboxClient.call(:flaky, %{})
    end
  end

  test "verify! reports missing calls" do
    owner =
      spawn(fn ->
        Sandbox.expect(SandboxClient, :mutate, fn _ -> %EchoResponse{} end)

        receive do
          :stop -> :ok
        end
      end)

    Process.sleep(50)

    assert_raise Sandbox.VerificationError, ~r/Mutate: 1 call/, fn -> Sandbox.verify!(owner) end
    send(owner, :stop)
  end

  test "ambiguous names need the service" do
    assert {:error, %ArgumentError{message: message}} = SandboxClient.call(:echo, %{})
    assert message =~ "ambiguous"
    assert {:error, %ArgumentError{message: "unknown rpc :nope"}} = SandboxClient.call(:nope, %{})

    Sandbox.expect(SandboxClient, :say_hello, fn _ -> %EchoResponse{message: "hello"} end)
    assert {:ok, %EchoResponse{message: "hello"}} = SandboxClient.call(:say_hello, %{})

    Sandbox.expect(SandboxClient, {GreeterService.Service, :echo}, fn _ ->
      %EchoResponse{message: "greeter"}
    end)

    assert {:ok, %EchoResponse{message: "greeter"}} =
             SandboxClient.call({GreeterService.Service, "Echo"}, %{})

    assert {:ok, %EchoResponse{}} =
             (fn ->
                Sandbox.expect(SandboxClient, "/ash_grpc.test.v1.EchoService/Echo", fn _ ->
                  %EchoResponse{}
                end)

                SandboxClient.call("ash_grpc.test.v1.EchoService/Echo", %{})
              end).()
  end

  test "health and channel in sandbox mode" do
    assert %{status: :sandbox} = SandboxClient.health()
    assert {:error, %GRPC.RPCError{status: 14}} = SandboxClient.channel()
  end
end
