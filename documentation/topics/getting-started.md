# Getting started: serving

This guide exposes an Ash domain as a gRPC service, generates its `.proto` file and calls it
with `grpcurl`.

## 1. Add the extensions

Add `AshGrpc.Resource` to the resources you want to expose and `AshGrpc.Domain` to their domain.

```elixir
defmodule MyApp.Library.Book do
  use Ash.Resource,
    domain: MyApp.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :author, :string, public?: true
    attribute :status, MyApp.Library.BookStatus, default: :draft, public?: true
    create_timestamp :inserted_at, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title, :author, :status], update: [:title, :author, :status]]

    read :list do
      argument :author, :string
      filter expr(is_nil(^arg(:author)) or author == ^arg(:author))
      pagination keyset?: true, required?: false, countable: true
    end
  end

  grpc do
    # message fields, in order (default: public attributes)
    fields [:id, :title, :author, :status, :inserted_at]

    rpc :get_book, :read, kind: :get
    rpc :list_books, :list
    rpc :watch_books, :read, kind: :server_stream
    rpc :create_book, :create
    rpc :update_book, :update, update_mask?: true
    rpc :delete_book, :destroy
  end
end
```

```elixir
defmodule MyApp.Library do
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    package "myapp.library.v1"             # versioned, buf STANDARD style
    # file "myapp/library/v1/library.proto"  (default: derived from the package)
    # module_prefix MyApp.Grpc.Library.V1     (default: camelized package)
    # service "LibraryService"                (default: <LastUnversionedSegment>Service)
  end

  resources do
    resource MyApp.Library.Book
  end
end
```

Each rpc is backed by an action. Its kind is derived when you leave it out. A `read` becomes
`:get` when the action is `get?` or `get_by` is set, and `:list` otherwise. `create`, `update`
and `destroy` map to themselves, and a generic action becomes `:action`. Streaming kinds are
always explicit. The request and response shapes of each kind are listed in
[Protocol details](protocol-and-compatibility.md#actions-and-rpcs).

The generated proto for the resource above looks like this:

```proto
service LibraryService {
  rpc GetBook(GetBookRequest) returns (Book) { option idempotency_level = NO_SIDE_EFFECTS; }
  rpc ListBooks(ListBooksRequest) returns (ListBooksResponse) { ... }
  rpc WatchBooks(WatchBooksRequest) returns (stream Book) { ... }
  rpc CreateBook(CreateBookRequest) returns (Book);
  rpc UpdateBook(UpdateBookRequest) returns (Book);
  rpc DeleteBook(DeleteBookRequest) returns (google.protobuf.Empty);
}

message Book {
  string id = 1;
  string title = 2;
  optional string author = 3;
  optional BookStatus status = 4;
  google.protobuf.Timestamp inserted_at = 5;
}
```

## 2. Define an endpoint and start the server

```elixir
defmodule MyApp.GrpcEndpoint do
  use AshGrpc.Endpoint,
    otp_app: :my_app,
    domains: [MyApp.Library],
    interceptors: [AshGrpc.Interceptors.Logger],
    reflection: true,   # needs the optional :grpc_reflection dependency
    health: true        # grpc.health.v1 (the default)
end
```

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 50051}
]
```

The endpoint compiles the message and service modules from the DSL when it compiles. No
`protoc` is needed and there are no generated Elixir files. See `AshGrpc.Endpoint` for all
options (message size, page sizes, compressors, extra hand-written servers) and
`AshGrpc.Server` for TLS, the bind address and `port: 0`.

Serve a domain from one endpoint only, because the generated modules are global.

## 3. Generate the `.proto` files and the lock

```shell
mix ash_grpc.codegen
```

This writes:

* `priv/protos/myapp/library/v1/library.proto`, which you share with the teams calling you,
* `priv/grpc/ash_grpc.lock.json`, the field-number lock,
* `priv/grpc/snapshots/**.json`, the baseline for the next breaking-change check.

Commit all three. The lock is what keeps field numbers stable when fields are reordered,
added or removed (see [compatibility](protocol-and-compatibility.md#field-numbers-and-the-lock)).
Until the lock is up to date the endpoint compiles with provisional numbers and warns. Make
that an error in production:

```elixir
# config/prod.exs
config :ash_grpc, require_lock?: true
```

`mix ash.codegen` runs AshGrpc's codegen as well, so the usual workflow already covers it.

## 4. Call it

With reflection enabled, `grpcurl` needs no `.proto` files:

```shell
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext localhost:50051 describe myapp.library.v1.Book

grpcurl -plaintext -d '{"title": "Dune", "author": "Herbert"}' \
  localhost:50051 myapp.library.v1.LibraryService/CreateBook

grpcurl -plaintext -d '{"page_size": 10}' \
  localhost:50051 myapp.library.v1.LibraryService/ListBooks

grpcurl -plaintext -d '{"id": "…", "title": "Dune Messiah", "update_mask": "title"}' \
  localhost:50051 myapp.library.v1.LibraryService/UpdateBook

grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check
```

An Elixir client is a `use AshGrpc.Client` module over the endpoint's own service modules
(see [Consuming external services](consuming-services.md)):

```elixir
defmodule MyApp.LibraryClient do
  use AshGrpc.Client, otp_app: :my_app, services: [MyApp.Library.V1.LibraryService.Service]
end
```

## What you get for free

* Ash validations become `INVALID_ARGUMENT` with `google.rpc.BadRequest` field violations,
  policies become `PERMISSION_DENIED`, and missing records become `NOT_FOUND`
  ([errors](protocol-and-compatibility.md#errors)).
* The incoming `grpc-timeout` becomes the Ash action timeout, and it is propagated to the
  `AshGrpc.Client` calls made while handling the request.
* Telemetry: `[:ash_grpc, :server, :rpc, :start | :stop | :exception]`.
* `grpc.health.v1.Health` for Kubernetes probes, Envoy and load balancers.

Next: [auth, tenancy and interceptors](auth-tenancy-interceptors.md) and
[testing](testing.md).
