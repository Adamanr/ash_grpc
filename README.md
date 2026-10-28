# AshGrpc

[![CI](https://github.com/Adamanr/ash_grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/Adamanr/ash_grpc/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

gRPC for the [Ash Framework](https://ash-hq.org), in both directions:

* **Serve**: describe gRPC APIs next to your resources (`grpc do ... end`) and get a running
  gRPC server, plus `.proto` files to hand to other teams. Field numbers stay stable, and a
  breaking-change check runs in CI.
* **Consume**: connect to any number of external gRPC services (`use AshGrpc.Client`), import
  their `.proto` files, and call them from Ash, either as generic actions (`AshGrpc.Rpc`) or as
  whole resources backed by a remote service (`AshGrpc.DataLayer`).

AshGrpc is Ash-native by default and protobuf-correct always, with an escape hatch at every
level. Behind that sit AIP conventions (pagination, update and read masks), rich errors
(`google.rpc.BadRequest`, `ErrorInfo`), health checks, server reflection, deadlines and
retries, telemetry, and a test sandbox.

## Installation

```elixir
def deps do
  [
    {:ash_grpc, "~> 0.1"},
    # optional: server reflection (grpcurl, Postman, grpcui)
    {:grpc_reflection, "~> 0.5"}
  ]
end
```

With [Igniter](https://hexdocs.pm/igniter), run `mix igniter.install ash_grpc` (or
`mix ash_grpc.install` once the dependency is added). It creates an endpoint, adds the server
to your supervision tree and requires the field-number lock in production.

`protoc` is only needed to import foreign `.proto` files. Your own services are compiled from
the DSL directly.

## Quick start: serving

```elixir
defmodule MyApp.Library.Book do
  use Ash.Resource,
    domain: MyApp.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGrpc.Resource]

  # attributes, actions, ...

  grpc do
    fields [:id, :title, :author, :status, :inserted_at]

    rpc :get_book, :read, kind: :get
    rpc :list_books, :read                      # page_size / page_token / next_page_token
    rpc :watch_books, :read, kind: :server_stream
    rpc :create_book, :create
    rpc :update_book, :update, update_mask?: true
    rpc :delete_book, :destroy
  end
end

defmodule MyApp.Library do
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    package "myapp.library.v1"
  end

  resources do
    resource MyApp.Library.Book
  end
end

defmodule MyApp.GrpcEndpoint do
  use AshGrpc.Endpoint,
    otp_app: :my_app,
    domains: [MyApp.Library],
    interceptors: [AshGrpc.Interceptors.Logger],
    reflection: true
end

# application.ex
children = [{AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 50051}]
```

```shell
mix ash_grpc.codegen             # priv/protos/**/*.proto + field-number lock
mix ash_grpc.codegen --check     # in CI: stale output or breaking changes fail the build
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext -d '{"title": "Dune"}' localhost:50051 myapp.library.v1.LibraryService/CreateBook
```

## Quick start: consuming

```elixir
# compile the foreign service's .proto (or generate files with `mix ash_grpc.import`)
defmodule MyApp.Proto.Billing do
  use AshGrpc.Protos,
    files: ["priv/protos/billing/v1/billing.proto"],
    include: ["priv/protos"],
    module_prefix: MyApp.Proto
end

defmodule MyApp.Billing do
  use AshGrpc.Client, otp_app: :my_app, services: [MyApp.Proto.BillingService.Service]
end

# config/runtime.exs
config :my_app, MyApp.Billing, address: "dns:///billing.internal:50051", deadline: 5_000

# application.ex
children = [MyApp.Billing]

{:ok, invoice} = MyApp.Billing.call(:get_invoice, %{id: "inv_1"})
```

Back an Ash resource by the remote service, so that policies, calculations and code
interfaces work on top of it:

```elixir
defmodule MyApp.Billing.Invoice do
  use Ash.Resource, domain: MyApp.Billing.Domain, data_layer: AshGrpc.DataLayer

  grpc_remote do
    client MyApp.Billing
    message MyApp.Proto.Invoice
    read :list_invoices, filter: [:customer_id]
    get :get_invoice, by: :id
    create :create_invoice
    update :update_invoice, update_mask: :update_mask
    destroy :delete_invoice
  end

  # attributes and actions as usual
end
```

## Guides

* [Getting started: serving](documentation/topics/getting-started.md)
* [Consuming external services](documentation/topics/consuming-services.md)
* [Protocol details and compatibility](documentation/topics/protocol-and-compatibility.md)
* [Auth, tenancy and interceptors](documentation/topics/auth-tenancy-interceptors.md)
* [Testing](documentation/topics/testing.md)
* [Escape hatches](documentation/topics/escape-hatches.md)
* DSL references: [`AshGrpc.Resource`](documentation/dsls/DSL-AshGrpc.Resource.md),
  [`AshGrpc.Domain`](documentation/dsls/DSL-AshGrpc.Domain.md),
  [`AshGrpc.DataLayer`](documentation/dsls/DSL-AshGrpc.DataLayer.md)

The [example app](https://github.com/Adamanr/ash_grpc/tree/main/examples) runs two services: one serving with AshGrpc, one
consuming it through a remote resource. [DESIGN.md](DESIGN.md) describes the architecture.
