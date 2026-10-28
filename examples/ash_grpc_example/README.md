# AshGrpc example: library and front desk

Two services in one small Mix project:

* **`Library`** serves a book catalogue with AshGrpc (`lib/library`). It is an Ash domain with
  an ETS-backed `Library.Book` resource, a `grpc` DSL, policies (writes need an actor), and
  `Library.GrpcEndpoint` with reflection, health and an actor interceptor.
* **`Frontdesk`** consumes it (`lib/frontdesk`). It owns no data. It knows the library only
  through its published `.proto` file (`priv/protos/library/v1/library.proto`, compiled by
  `Frontdesk.Proto` with `use AshGrpc.Protos`), and it reaches it through:
  * `Frontdesk.Book`, a resource whose data layer is the library service
    (`AshGrpc.DataLayer`),
  * `Frontdesk.Inventory.count_available`, a generic action calling one rpc (`AshGrpc.Rpc`),
  * `Frontdesk.LibraryClient`, which sends the Ash actor as `authorization: Bearer <name>`, so
    the library's policies see who is acting.

```text
Frontdesk.add_book!("Dune", actor: %{name: "ada"})
  └─ AshGrpc.DataLayer ─► Frontdesk.LibraryClient ── gRPC ──► Library.GrpcEndpoint
                                                               └─ Ash.create(Library.Book, actor: ada)
```

## Requirements

Elixir 1.18 and OTP 27. `protoc` is needed to compile `Frontdesk.Proto`, and `grpcurl` is
optional.

```shell
mix deps.get
mix test
```

## Running the services

Both services in one node (the library listens on port 50051):

```shell
iex -S mix
```

```elixir
iex> ada = %{name: "ada"}
iex> Frontdesk.add_book!("Dune", %{author: "Herbert", genre: :fiction, copies: 2}, actor: ada)
iex> Frontdesk.list_books!()
iex> Frontdesk.count_available!()
iex> Frontdesk.add_book("Anonymous")          # {:error, %Ash.Error.Forbidden{}}
```

Or as two separate nodes, which is closer to production:

```shell
SERVICES=library LIBRARY_PORT=50051 mix run --no-halt
SERVICES=frontdesk LIBRARY_ADDRESS=localhost:50051 iex -S mix
```

## Calling the library with grpcurl

The endpoint serves reflection, so grpcurl needs no `.proto` files:

```shell
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext localhost:50051 describe library.v1.LibraryService
grpcurl -plaintext localhost:50051 describe library.v1.Book

# writes need an actor
grpcurl -plaintext -H 'authorization: Bearer ada' \
  -d '{"title": "Dune", "author": "Herbert", "genre": "GENRE_FICTION", "copies": 2}' \
  localhost:50051 library.v1.LibraryService/CreateBook

# without one: PermissionDenied
grpcurl -plaintext -d '{"title": "Anonymous"}' localhost:50051 library.v1.LibraryService/CreateBook

# list with a pushed-down filter and pagination
grpcurl -plaintext -d '{"author": "Herbert", "page_size": 10}' \
  localhost:50051 library.v1.LibraryService/ListBooks

# partial update with an update mask (use an id returned above)
grpcurl -plaintext -H 'authorization: Bearer ada' \
  -d '{"id": "<id>", "copies": 5, "update_mask": "copies"}' \
  localhost:50051 library.v1.LibraryService/UpdateBook

# validation errors: InvalidArgument with google.rpc.BadRequest details
grpcurl -plaintext -H 'authorization: Bearer ada' -d '{"title": "Bad", "copies": -1}' \
  localhost:50051 library.v1.LibraryService/CreateBook

# server streaming, generic action, health
grpcurl -plaintext localhost:50051 library.v1.LibraryService/WatchBooks
grpcurl -plaintext localhost:50051 library.v1.LibraryService/CountAvailable
grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check
```

grpcurl prints error details (`BadRequest`, `ErrorInfo`) as raw `@value` bytes, because
reflection only describes the library's own service. Clients built with AshGrpc, or with any
gRPC library that ships the `google.rpc` protos, decode them.

## Changing the API

After changing `Library.Book` or `Library`, regenerate the contract:

```shell
mix ash_grpc.codegen          # updates priv/protos, priv/grpc/ash_grpc.lock.json and snapshots
mix ash_grpc.codegen --check  # what CI runs
```

`Frontdesk.Proto` recompiles from the updated `.proto` file. Removed fields stay reserved, so
an old front desk keeps working against a newer library.
