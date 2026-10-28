# Testing

## Code that calls other services: the client sandbox

Put the client into sandbox mode in `config/test.exs`. No connection is opened, and every call
is answered by an expectation or stub defined in the test:

```elixir
# config/test.exs
config :my_app, MyApp.Billing, sandbox: true
```

```elixir
defmodule MyApp.CheckoutTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Client.Sandbox

  test "charges the card" do
    Sandbox.expect(MyApp.Billing, :charge, fn %MyApp.Proto.ChargeRequest{amount: 100} ->
      {:ok, %MyApp.Proto.ChargeResponse{id: "ch_1"}}
    end)

    assert {:ok, %{id: "ch_1"}} = MyApp.Checkout.pay(100)
    Sandbox.verify!()
  end

  # with `retry: [...]` configured and an idempotent rpc
  test "retries an unavailable service" do
    Sandbox.expect(MyApp.Billing, :get_invoice, fn _ -> {:error, :unavailable} end)
    Sandbox.expect(MyApp.Billing, :get_invoice, fn _ -> {:ok, %MyApp.Proto.Invoice{id: "i"}} end)

    assert {:ok, %{id: "i"}} = MyApp.Billing.call(:get_invoice, %{id: "i"})
  end

  test "remote validation errors" do
    Sandbox.stub(MyApp.Billing, :charge, fn _req, %{metadata: metadata} ->
      assert metadata["authorization"]
      {:error, {:invalid_argument, "amount must be positive"}}
    end)

    assert {:error, %Ash.Error.Invalid{}} = MyApp.Checkout.pay(-1)
  end
end
```

Everything above the transport still runs: rpc resolution, request building, deadlines,
metadata, retries, telemetry and error mapping. Expectations belong to the test process and are
visible to the processes it starts, found through `$callers`, so `Task`s and Ash internals work
and tests can be `async: true`. Other processes can be allowed with `Sandbox.allow/2`. Remote
resources (`AshGrpc.DataLayer`) and `AshGrpc.Rpc` actions go through the same clients, so they
are sandboxed too. To return `BadRequest` field violations, build a `GRPC.RPCError` with
`details: [AshGrpc.Error.Details.pack(%Google.Rpc.BadRequest{...})]`.

See `AshGrpc.Client.Sandbox` for the return values and for streaming rpcs.

## Testing your own gRPC API: an in-test server

Start the endpoint on a free port and call it with a real client. This covers the codec, the
errors, the interceptors and the transport:

```elixir
defmodule MyApp.GrpcEndpointTest do
  use MyApp.DataCase, async: false

  defmodule Client do
    use AshGrpc.Client, otp_app: :my_app, services: [MyApp.Library.V1.LibraryService.Service]
  end

  setup_all do
    start_supervised!({AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 0})
    port = AshGrpc.Server.port(MyApp.GrpcEndpoint)
    start_supervised!({Client, address: "127.0.0.1:#{port}", map_errors: false})
    :ok
  end

  test "creates a book" do
    assert {:ok, %{title: "Dune"}} = Client.call(:create_book, %{title: "Dune"})
  end

  test "validation errors carry field violations" do
    assert {:error, %GRPC.RPCError{status: 3, details: details}} =
             Client.call(:create_book, %{title: ""})

    assert [%Google.Rpc.BadRequest{field_violations: [%{field: "title"}]}] =
             for %Google.Rpc.BadRequest{} = d <- AshGrpc.Error.Details.unpack_all(details), do: d
  end
end
```

Things to keep in mind:

* Every request is handled in its own process. Data layers that are private to the test
  process (`ets private?: true`, an Ecto sandbox in `:manual` mode without allowances) are not
  visible to the handler. Use shared mode (`Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared,
  self()})`, hence `async: false`) or allow the handler processes.
* `AshGrpc.Server.port/1` returns the port picked by `port: 0`.
* Pass `start_server: false` to start only the support processes (health, reflection) when a
  test does not need a socket.

## Checking the contract in CI

```shell
mix ash_grpc.codegen --check
```

The check fails when the committed protos or the lock are stale, or when a change breaks the
wire format (see [compatibility](protocol-and-compatibility.md#breaking-change-check-in-ci)).
If you import foreign protos with `mix ash_grpc.import`, `mix ash_grpc.import ... --check`
fails when the generated modules are stale.
