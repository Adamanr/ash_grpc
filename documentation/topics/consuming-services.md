# Consuming external services

AshGrpc can call any gRPC service, not only AshGrpc servers. There are four layers, and each
one builds on the previous:

1. **protobuf modules** for the foreign `.proto` files (`use AshGrpc.Protos` or
   `mix ash_grpc.import`),
2. **a client** per service (`use AshGrpc.Client`): connections, deadlines, retries, metadata,
3. **generic actions** calling one rpc (`AshGrpc.Rpc`),
4. **remote resources** backed by a service (`AshGrpc.DataLayer`).

## Importing `.proto` files

You can compile at build time, so no generated files end up in git:

```elixir
defmodule MyApp.Proto.Billing do
  use AshGrpc.Protos,
    files: ["priv/protos/billing/v1/billing.proto"],
    include: ["priv/protos"],
    module_prefix: MyApp.Proto
end
```

Or you can generate source files and commit them:

```shell
mix ash_grpc.import priv/protos/billing/**/*.proto -I priv/protos --module-prefix MyApp.Proto
mix ash_grpc.import ... --check    # CI: fails when the generated files are stale
```

Both run `protoc` to read the files and compile the modules through AshGrpc's own compiler.
The modules have the same shape as `protoc-gen-elixir` output (`MyApp.Proto.Invoice`,
`MyApp.Proto.BillingService.Service`, `...BillingService.Stub`), including `descriptor/0`.
Well-known types (`google.protobuf.*`) and the Google API types (`google.type.*`,
`google.rpc.*`) are not regenerated: they resolve to the modules of the `protobuf` and
`googleapis` libraries.

With `use AshGrpc.Protos`, `protoc` must be installed wherever the project compiles. With
`mix ash_grpc.import` it is only needed when the files are regenerated.

## Clients

```elixir
defmodule MyApp.Billing do
  use AshGrpc.Client, otp_app: :my_app, services: [MyApp.Proto.BillingService.Service]
end
```

```elixir
# config/runtime.exs
config :my_app, MyApp.Billing,
  address: "dns:///billing.internal:50051",
  tls: [cacertfile: "/etc/ssl/billing-ca.pem"],  # false (default), true, ssl opts or a GRPC.Credential
  pool_size: 4,
  deadline: 5_000,                                # always sent; covers all retry attempts
  retry: [max_attempts: 3, backoff: {:exponential, 50, 2_000}, on: [:unavailable]],
  metadata: {MyApp.Billing.Auth, :metadata, []},
  compression: :gzip

# application.ex
children = [MyApp.Billing]
```

```elixir
{:ok, invoice} = MyApp.Billing.call(:get_invoice, %{id: "inv_1"})
{:ok, invoice} = MyApp.Billing.call(:GetInvoice, %MyApp.Proto.GetInvoiceRequest{id: "inv_1"},
                                    deadline: 1_000, metadata: %{"x-request-id" => id})
{:ok, stream} = MyApp.Billing.stream(:watch_invoices, %{customer_id: "c1"})
{:ok, summary} = MyApp.Billing.stream(:import_invoices, Stream.map(rows, &to_request/1))
```

Every client has its own supervisor and pool, so an application can talk to as many services
as it needs. Requests can be structs or plain maps (nested maps become messages). An rpc can be
named by its proto name, its snake_case name, or its full path (`AshGrpc.Client.RpcTable`).
Configuration can be completed at startup with an `init/1` callback, as with `Ecto.Repo`.
Clients can also be started dynamically with `AshGrpc.Client.start_link/1`. The full option
reference is in `AshGrpc.Client.Config`.

### Connections

The pool keeps `pool_size` HTTP/2 connections. Each of them resolves the address (`dns:///`
targets are re-resolved periodically) and balances across the resolved addresses
(`lb_policy: :round_robin`). Connections are dialed in the background and never fail the
supervisor. A call waits up to `connect_timeout` (capped by its deadline) for a connection that
is still being established. When a call fails because its connection is gone, the connection is
re-dialed for the next attempt (see `AshGrpc.Client.Pool`).

### Retries

Only **idempotent** rpcs are retried. An rpc is idempotent when its service declares
`idempotency_level` `NO_SIDE_EFFECTS` or `IDEMPOTENT` (AshGrpc servers do this for every read),
when it is listed in the client's `idempotent:` option, or when the call passes
`idempotent: true`. Retries use exponential backoff with full jitter and stop as soon as the
next delay would not fit into the deadline (`AshGrpc.Client.Retry`).

### Deadlines

Every call sends a deadline, taken from the call's `deadline:` or the client default. Inside an
AshGrpc server handler, the remaining deadline of the incoming request caps it automatically.
Elsewhere you can set it with `AshGrpc.Client.put_deadline/1`.

### Metadata and the actor

`metadata:` is a map, an MFA or a function receiving `%{client:, service:, rpc:, opts:}`.
`opts` holds the call options, including the `:actor` and `:tenant` that `AshGrpc.Rpc` and
`AshGrpc.DataLayer` pass along. Use it to propagate identity:

```elixir
def metadata(%{opts: opts}) do
  case opts[:actor] do
    %{id: id} -> %{"authorization" => "Bearer " <> MyApp.Tokens.sign(id)}
    nil -> %{}
  end
end
```

### Errors

By default, failed calls return Ash errors (`map_errors: true`). `INVALID_ARGUMENT` with
`BadRequest` details becomes `Ash.Error.Invalid` with one error per field violation,
`NOT_FOUND` becomes `Ash.Error.Query.NotFound`, `PERMISSION_DENIED` and `UNAUTHENTICATED`
become `Ash.Error.Forbidden`, and everything else becomes `Ash.Error.Unknown` wrapping an
`AshGrpc.Error.RemoteError` with the status and decoded details. Pass `map_errors: false`
(client or call) to get the raw `GRPC.RPCError`.

### Telemetry

`[:ash_grpc, :client, :rpc, :start | :stop | :exception]`, with `client`, `service`, `rpc`,
`status` and `attempts` in the metadata (`AshGrpc.Client.Call`).

## Generic actions: `AshGrpc.Rpc`

```elixir
action :charge, :struct do
  constraints instance_of: MyApp.Billing.Charge
  argument :amount, :integer, allow_nil?: false
  argument :currency, :string, default: "EUR"

  run {AshGrpc.Rpc, client: MyApp.Billing, rpc: :charge, response: :charge}
end
```

Arguments whose names match request fields are encoded with the argument types, so enums,
timestamps and nested maps all work. `request:` builds the request yourself.

The response is decoded into the action's return type. That can be the whole message, a field
path given with `response:`, or the result of a function. A message decoded into a resource
type is mapped by attribute name. `BadRequest` violations are reported on the arguments behind
the violated fields. See `AshGrpc.Rpc`.

## Remote resources: `AshGrpc.DataLayer`

```elixir
defmodule MyApp.Tickets.Ticket do
  use Ash.Resource, domain: MyApp.Tickets, data_layer: AshGrpc.DataLayer

  grpc_remote do
    client MyApp.TicketsClient
    message MyApp.Proto.Ticket          # the record message
    fields owner: "owner_id"            # attribute => proto field, when they differ
    page_size 100

    read :list_tickets, filter: [:owner, :status]
    get :get_ticket, by: :id
    create :create_ticket, request: :ticket           # AIP style { Ticket ticket = 1; }
    update :update_ticket, request: :ticket, update_mask: :update_mask
    destroy :delete_ticket
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :owner, :string, public?: true
    attribute :status, :atom, constraints: [one_of: [:open, :closed]], public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

How reads and writes work:

* Equality filters on the attributes listed in `filter:` are sent as request fields. The full
  filter is then applied in memory, so every Ash filter still works. Use
  `strict_filters? true` to reject filters that cannot be pushed down.
* `Ash.get/2` and other reads that pin every `by` attribute call the `get` rpc.
* Reads follow `next_page_token` (AIP-158) for up to `max_pages` pages. Sort, offset and limit
  are applied in memory, and Ash pagination works on top.
* Updates fill the `update_mask` with the proto names of the changed attributes.
* Enums match by value name: `TICKET_STATUS_OPEN` and `OPEN` both match `:open`.
* Policies, calculations, aggregates over loaded data, validations and code interfaces work as
  with any data layer. There are no transactions: every action is one or more independent
  calls.

The actor and tenant reach the client's `:metadata` function as call options, so a remote
AshGrpc server sees the same actor and its policies apply on both ends.
`test/e2e/remote_resource_test.exs` in the AshGrpc repository shows this end to end.

Tests for code that uses clients are covered in [Testing](testing.md).
