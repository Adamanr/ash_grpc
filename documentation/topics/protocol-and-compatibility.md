# Protocol details and compatibility

## Naming

The generated protos follow the buf `STANDARD` lint rules (codegen's `--buf` writes a matching
`buf.yaml`):

* packages are `lower.snake.v1` (a verifier warns about unversioned packages),
* messages, enums and services are `PascalCase`, and service names end with `Service`,
* fields are `lower_snake_case`, with a trailing `?`/`!` stripped (`admin?` → `admin`),
* enum values are `UPPER_SNAKE` prefixed with the enum name, and value 0 is
  `<ENUM>_UNSPECIFIED`,
* an rpc is the `PascalCase` DSL name (`:get_book` → `GetBook`), with `GetBookRequest` /
  `GetBookResponse` messages. Standard methods return the resource message (`Get`, `Create`,
  `Update`) or `google.protobuf.Empty` (`Delete`).
* the repeated field of a list response is the resource's `plural_name`, otherwise a naive
  plural of the message name. Set `plural_name` for irregular plurals (`shelf` → `shelves`).

## Field numbers and the lock

Renumbering or reusing a field number is the most common way to break protobuf clients.
AshGrpc numbers fields like this:

* An explicit `field :name, number: 3` always wins.
* Otherwise the number comes from the lock (`priv/grpc/ash_grpc.lock.json`). A new field gets
  the next free number, skipping 19000–19999 and reserved numbers, and `mix ash_grpc.codegen`
  records it in the lock.
* **Removing a field reserves its number and name**, both in the lock and in the `.proto`
  (`reserved 3; reserved "size";`). Re-adding a reserved name later fails with a conflict
  instead of silently reusing the old number.
* Reordering `fields` does not change numbers.

```text
V1: string id = 1; string name = 2; optional int64 size = 3; Timestamp inserted_at = 4;
V2: ... + optional string color = 5;                     (numbers 1–4 unchanged)
V3: reserved 3, 5; reserved "color", "size";
    string id = 1; string name = 2; Timestamp inserted_at = 4;
```

Clients compiled from V1 keep working against V2 and V3 servers: unknown fields are skipped,
and fields the server no longer has decode as absent. `test/e2e/compatibility_test.exs`
exercises exactly this.

When the lock is missing or stale, the endpoint still compiles with deterministic provisional
numbers and emits a warning. With `config :ash_grpc, require_lock?: true` (recommended in
`config/prod.exs`) that becomes a compile error.

### Breaking-change check in CI

```shell
mix ash_grpc.codegen --check          # or: mix ash.codegen --check
```

The check fails when the committed `.proto` files, snapshots or lock are stale. It also fails
on wire-breaking changes compared to the last snapshots (`AshGrpc.Proto.Diff`, a subset of buf's
`WIRE_JSON` rules):

* a field number was changed or reused,
* a field type was changed to an incompatible one,
* a label was changed (singular ↔ repeated),
* a field or enum value was removed without reservation,
* an rpc was removed or renamed,
* a request or response type was changed,
* a streaming kind was changed,
* the package was changed,
* an enum value number was changed.

A plain `mix ash_grpc.codegen` with breaking changes writes nothing unless you pass
`--allow-breaking`, so accepting a break is always a deliberate decision.
`--dry-run` prints the pending changes. If you also use buf, `buf breaking` against the
generated directory works as well.

## Type mapping

| Ash type | proto (default) | alternatives (`representation:`) |
|---|---|---|
| `:string`, `:ci_string` | `string` | `bytes`, `google.protobuf.StringValue` |
| `:integer` | `int64` | any integer scalar, `string`, wrapper values |
| `:float` | `double` | `float`, `string`, wrapper values |
| `:decimal` | `string` | `google.type.Decimal` (never a float) |
| `:boolean` | `bool` | `google.protobuf.BoolValue` |
| `:uuid`, `:uuid_v7` | `string` | `bytes` (16 raw bytes) |
| `:binary` | `bytes` | `google.protobuf.BytesValue` |
| `:date` | `google.type.Date` | `string` (ISO-8601) |
| `:time` | `google.type.TimeOfDay` | `string` |
| `:utc_datetime(_usec)`, `:datetime` | `google.protobuf.Timestamp` | `string` |
| `:naive_datetime` | `string` (ISO-8601) | |
| `:duration` | `google.protobuf.Duration` | `string` |
| `Ash.Type.Enum`, `:atom` + `one_of` | `enum` (`*_UNSPECIFIED = 0`) | `string` |
| `:map` without `fields` | `google.protobuf.Struct` | `string` (JSON) |
| `:map`/`:struct`/`:keyword`/`:tuple` with `fields` | nested message | `Struct`, `string` |
| `Ash.Type.Union` | wrapper message with `oneof value` | `Struct`, `string` |
| embedded resource | its message | |
| `{:array, t}` | `repeated t` | applies to the items |
| `:term` | none: `representation:` required | `google.protobuf.Value`, `Struct`, `string` (JSON) |

The full table is in `AshGrpc.Type.Mapping`. Custom types implement `AshGrpc.Type`.

**Presence.** Nullable scalars and enums are proto3 `optional` (explicit presence), so `nil`
and the zero value are distinguishable. Required ones use implicit presence. Messages always
have presence. An `UNSPECIFIED` enum decodes to `nil`, or to a validation error when the field
is required.

In requests, an absent optional field means "not provided" and the Ash default applies; it
never means `nil`. To set `nil`, use the update mask or a `google.protobuf.*Value` wrapper via
`representation:`.

## Actions and rpcs

| kind | request | response |
|---|---|---|
| `:get` | `get_by` fields (default: primary key) + arguments (+ `read_mask`) | resource message; `NOT_FOUND` when missing |
| `:list` | arguments + `page_size`, `page_token` (+ `filter`, `order_by` with `filter?: true`) (+ `read_mask`) | `{ repeated <Msg> <plural> = 1; string next_page_token = 2; optional int64 total_size = 3; }` |
| `:server_stream` | arguments (+ `read_mask`) | `stream` resource message (`Ash.stream!/2` with backpressure) |
| `:create` | accepted attributes + arguments (`input: :wrapped` → `{ Book book = 1; ... }`) | resource message |
| `:update` | primary key + accepted + arguments (+ `update_mask`) | resource message |
| `:destroy` | primary key + arguments | `google.protobuf.Empty` (`return_destroyed?: true` → the record) |
| `:client_stream` (create) | `stream` create requests | `{ int64 count = 1; repeated google.rpc.Status errors = 2; }` (`Ash.bulk_create`) |
| generic action | arguments | `Empty`, the returned message, or `{ value = 1 }` for scalars/lists |
| `:bidi_stream` | `stream` of the action's request | `stream` of its response, `handler:` required |

Reads are marked `idempotency_level = NO_SIDE_EFFECTS`, which lets clients retry them safely.

## Pagination (AIP-158)

`page_size` defaults to the endpoint's `default_page_size` (or the action's `default_limit`,
otherwise 50). It is capped by `max_page_size`. Tokens are opaque:

* actions with keyset pagination only get keyset tokens, which are stable under concurrent
  inserts,
* actions with offset pagination (including the default `read`, which supports both) and
  actions without pagination get offset tokens.

`next_page_token` is empty on the last page. `total_size` is filled when the action's
pagination is `countable`.

## Masks and filters

* **Update mask (AIP-134)** with `update_mask?: true`: the paths are proto field names of the
  input. Only those inputs change. A listed field that is absent from the request is set to
  `nil`/`[]`, and fields that are not listed are ignored. Without a mask, the fields set in
  the request are applied. Repeated and map fields have no presence, so they cannot say "not
  set": send a mask for partial updates.
* **Read mask (AIP-157)** with `read_mask?: true`: it selects attributes (the primary key is
  always included) and loads only the listed calculations, aggregates and relationships.
* **Filter and order (AIP-160/132)** with `filter?: true` on `:list` rpcs: `filter` is a JSON
  object in Ash's input filter syntax (`{"price": {"gt": 10}}`), applied with
  `Ash.Query.filter_input/2` so that field policies are honoured. `order_by` is
  `"title desc, inserted_at"`.

## Errors

| Ash | gRPC status | details |
|---|---|---|
| validation errors (`Ash.Error.Invalid`) | `INVALID_ARGUMENT` | `google.rpc.BadRequest`, field = proto field path |
| `Ash.Error.Query.NotFound` | `NOT_FOUND` | `google.rpc.ResourceInfo` |
| `Ash.Error.Forbidden` | `PERMISSION_DENIED` | no policy breakdown |
| actor required, `AshGrpc.Error.Unauthenticated` | `UNAUTHENTICATED` | |
| `Ash.Error.Changes.StaleRecord` | `ABORTED` | |
| unique constraint violation | `ALREADY_EXISTS` | `google.rpc.BadRequest` |
| timeouts | `DEADLINE_EXCEEDED` | |
| anything else | `INTERNAL` | message hidden unless `show_raised_errors?` |

Every status carries a `google.rpc.ErrorInfo`. Details travel as `google.rpc.Status` in the
`grpc-status-details-bin` trailer, the standard rich error model that grpc-go, grpc-java and
the other mainstream implementations decode. Internal error messages never go over the wire
unless `config :ash_grpc, show_raised_errors?: true`, which is meant for development only.
Internal errors are logged on the server with their stacktrace.

Add your own exceptions with the `AshGrpc.ToStatus` protocol. On the client side the mapping
runs in reverse (see [Consuming](consuming-services.md#errors)).

## Deadlines, cancellation, limits

* The incoming `grpc-timeout` becomes the Ash action timeout, and it caps every
  `AshGrpc.Client` call made while handling the request.
* When a client cancels a server stream, the `Ash.stream!/2` consumer stops.
* The message size limit is `max_message_size` (4 MiB by default) on both the endpoint and the
  client. gzip compression is supported in both directions.
