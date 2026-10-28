# AshGrpc — Design

AshGrpc brings gRPC to the [Ash Framework](https://ash-hq.org) in both directions:

* **Serve** — describe gRPC APIs next to your Ash resources (`grpc do ... end`), get a running
  gRPC server *and* `.proto` files you can hand to other teams.
* **Consume** — connect to any number of external gRPC services, import their `.proto` files,
  and call them from Ash (generic actions, or whole resources backed by a remote service).

The guiding principle: **Ash-native by default, protobuf-correct always, with an escape hatch at
every level.**

---

## 1. What changed compared to the initial idea (and why)

The initial idea: multiple gRPC connectors, `grpc do end` in resources → generated `.proto`,
correct protocol details, both own and foreign `.proto`. On top of that this design adds:

| Addition | Why |
|---|---|
| **Single IR** (`AshGrpc.Proto.IR`) between every input and output | DSL, foreign `.proto`, renderer, Elixir compiler, diff all speak one language. Foreign and own protos are handled by the same machinery. |
| **Field-number lock file** (`priv/grpc/ash_grpc.lock.json`) | The #1 way to break protobuf clients is renumbering/reusing fields. Numbers are explicit *or* assigned once and locked; removed fields become `reserved` automatically. |
| **Breaking-change check** (`mix ash_grpc.codegen --check`) | CI fails if generated protos are stale or a change is wire-incompatible (like `buf breaking`), mirroring `mix ash.codegen --check`. |
| **No `protoc-gen-elixir` for own services** | Message/service modules are compiled from the IR at compile time; `.proto` files are an *output*, not an input. `protoc` is only needed to import foreign protos. |
| **Rich error model** | Ash errors ↔ gRPC status codes + `google.rpc.Status` details (`BadRequest.FieldViolation`, `ErrorInfo`, …) in `grpc-status-details-bin`. Clients get structured validation errors, not strings. |
| **AIP conventions out of the box** | Pagination (`page_size`/`page_token`/`next_page_token`, AIP-158), update masks (`FieldMask`, AIP-134), read masks (AIP-157), standard method naming (AIP-131..135). Opt-out per rpc. |
| **Health + reflection** | `grpc.health.v1` and server reflection are expected by k8s probes, grpcurl, Postman, Envoy. |
| **Client = Repo-like module** | `use AshGrpc.Client, otp_app: ...` per external service → config per env, supervised channel pool, deadlines, retries (only for idempotent methods), metadata/auth, telemetry, test sandbox. |
| **Remote data layer** | A resource can be backed by a foreign gRPC service (`AshGrpc.DataLayer`), so policies, calculations, code interfaces work over gRPC too. |
| **Telemetry/OpenTelemetry-friendly spans** | `[:ash_grpc, :server | :client, :rpc, :start | :stop | :exception]`. |

---

## 2. Architecture

```
                     ┌───────────────────────── compile time ──────────────────────────┐
 Ash resources ──►  AshGrpc.Resource / AshGrpc.Domain (Spark DSL)                         │
                     │   AshGrpc.Schema.build/2  (DSL → IR, uses Type.Mapping)           │
                     ▼                                                                   │
              AshGrpc.Proto.IR.Schema ──► Proto.Lock.assign (stable numbers)             │
                     │            ├──► Proto.Compiler  → Elixir protobuf/GRPC modules ───┼──► AshGrpc.Endpoint
                     │            └──► Proto.Render    → .proto files (mix ash_grpc.codegen)   (GRPC.Server +
 foreign .proto ──► Proto.Import (protoc descriptor set → IR) ──► Compiler → client stubs │    Handler → Ash actions)
                     └──────────────────────────────────────────────────────────────────┘
 runtime:  AshGrpc.Client (channels, pools, retries)  ◄── AshGrpc.Rpc (generic action impl)
                                                      ◄── AshGrpc.DataLayer (remote resources)
           AshGrpc.Codec  (Ash values ↔ protobuf structs)    AshGrpc.Error (Ash errors ↔ gRPC status)
```

### Module map and ownership (work packages)

| Module(s) | Package | Notes |
|---|---|---|
| `AshGrpc.Proto.IR`, `AshGrpc.Proto.WellKnown` | **foundation** (done) | the contract |
| `AshGrpc.Proto.Render`, `.Compiler`, `.Lock`, `.Diff` | **WP-A proto toolkit** | stubs exist with fixed signatures |
| `AshGrpc.Proto.Import`, `mix ash_grpc.import`, `use AshGrpc.Protos` | **WP-B import** | |
| `AshGrpc.Resource`, `AshGrpc.Domain`, `*.Info`, verifiers, `AshGrpc.Schema` | **WP-C DSL** | |
| `AshGrpc.Type`, `AshGrpc.Type.Mapping`, `AshGrpc.Codec`, `AshGrpc.Error` | **WP-D types/codec/errors** | `Type.Mapping` has a foundation version |
| `AshGrpc.Client*` | **WP-E clients** | |
| `AshGrpc.Endpoint`, `AshGrpc.Server*`, `AshGrpc.Interceptors.*`, health | **WP-F server** (phase 2) | |
| `mix ash_grpc.codegen`, Ash `codegen/1` hook, snapshots | **WP-G codegen** (phase 2) | |
| `AshGrpc.DataLayer`, `AshGrpc.Rpc` | **WP-H remote** (phase 2) | |
| guides, example app, e2e tests | **WP-I docs/e2e** (phase 3) | |

### Cross-package contracts (signatures are fixed; implementations may be stubs)

```elixir
# WP-A
AshGrpc.Proto.Render.render(IR.File.t(), opts) :: iodata()
AshGrpc.Proto.Compiler.quoted(IR.Schema.t(), opts) :: [{module, Macro.t()}]
AshGrpc.Proto.Compiler.compile(IR.Schema.t(), opts) :: [module]
AshGrpc.Proto.Compiler.to_source(IR.Schema.t(), opts) :: [{Path.t(), String.t()}]
AshGrpc.Proto.Lock.load(path) :: {:ok, Lock.t()} | {:error, term}
AshGrpc.Proto.Lock.assign(IR.File.t(), Lock.t()) :: {IR.File.t(), Lock.t()}
AshGrpc.Proto.Lock.write!(Lock.t(), path) :: :ok
AshGrpc.Proto.Diff.diff(old :: IR.Schema.t(), new :: IR.Schema.t()) :: [Diff.Change.t()]
  # Change: %{kind: atom, severity: :breaking | :safe, path: String.t(), message: String.t()}

# WP-B
AshGrpc.Proto.Import.from_files([Path.t()], include_paths: [...]) :: {:ok, IR.Schema.t()} | {:error, term}
AshGrpc.Proto.Import.from_descriptor_set(binary | Google.Protobuf.FileDescriptorSet.t(), opts) :: {:ok, IR.Schema.t()}

# WP-C
AshGrpc.Schema.build(domains :: [module], opts) :: {:ok, IR.Schema.t()} | {:error, [Exception.t()]}
  # opts: lock: Lock.t() | nil  (numbers are assigned via Lock.assign/2)
  # every IR node gets `source` (see IR docs) and `module` (Elixir module name to compile to)

# WP-D
AshGrpc.Type.Mapping.to_proto(ash_type, constraints, opts) :: {:ok, Mapping.Result.t()} | {:error, term}
AshGrpc.Codec.encode(value, ash_type, constraints, IR.field_type()) :: {:ok, proto_value} | {:error, term}
AshGrpc.Codec.decode(proto_value, ash_type, constraints, IR.field_type()) :: {:ok, value} | {:error, term}
AshGrpc.Codec.encode_record(record, IR.Message.t(), IR.Schema.t()) :: {:ok, struct} | {:error, term}
AshGrpc.Codec.decode_message(struct, IR.Message.t(), IR.Schema.t()) :: {:ok, %{atom => term}} | {:error, term}
AshGrpc.Error.to_rpc_error(Ash.Error.t() | term, opts) :: GRPC.RPCError.t()
AshGrpc.Error.from_rpc_error(GRPC.RPCError.t(), opts) :: Exception.t()

# WP-E
MyClient.call(rpc :: atom | String.t(), request :: struct | map, opts) :: {:ok, response} | {:error, Exception.t()}
MyClient.stream(rpc, request_or_enum, opts) :: {:ok, Enumerable.t()} | {:error, Exception.t()}
MyClient.channel(opts) :: {:ok, GRPC.Channel.t()} | {:error, term}
```

---

## 3. User-facing API

### 3.1 Exposing resources (serve)

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource, domain: MyApp.Accounts, extensions: [AshGrpc.Resource]

  grpc do
    message "User"                       # default: resource short name
    fields [:id, :email, :role, :profile, :inserted_at]   # default: public attributes
    # field-level fine tuning (all optional)
    field :id, number: 1
    field :role, number: 3, doc: "Access level"
    field :inserted_at, representation: :string          # override type mapping
    calculate :display_name, number: 10                  # expose calculations/aggregates
    relationship :posts, message: "Post", load?: false   # loaded relationships → nested messages
    reserved numbers: [4, 5], names: ["legacy_name"]

    rpc :get_user, :read, kind: :get, get_by: [:id]
    rpc :list_users, :read, kind: :list                  # page_size/page_token/next_page_token
    rpc :watch_users, :read, kind: :server_stream        # Ash.stream!/2 → server streaming
    rpc :create_user, :create
    rpc :update_user, :update, update_mask?: true        # google.protobuf.FieldMask
    rpc :delete_user, :destroy                           # returns google.protobuf.Empty
    rpc :import_users, :create, kind: :client_stream     # bulk create
    rpc :ping, :ping                                     # generic action
    rpc :sync, :sync, kind: :bidi_stream, handler: MyApp.Grpc.SyncHandler  # escape hatch
  end
end

defmodule MyApp.Accounts do
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    package "myapp.accounts.v1"
    file "myapp/accounts/v1/accounts.proto"
    service "AccountsService"            # default service for every rpc of this domain
    option :go_package, "github.com/acme/myapp/gen/accounts/v1;accountsv1"
    option :java_multiple_files, true
    module_prefix MyApp.Grpc.Accounts.V1 # Elixir modules for messages/services
  end

  resources do
    resource MyApp.Accounts.User
  end
end

defmodule MyApp.GrpcEndpoint do
  use AshGrpc.Endpoint,
    otp_app: :my_app,
    domains: [MyApp.Accounts],
    interceptors: [AshGrpc.Interceptors.Logger, {AshGrpc.Interceptors.Actor, from: MyApp.Grpc.Auth}],
    reflection: true,
    health: true
end

# application.ex
children = [{AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 50051}]
```

```shell
mix ash_grpc.codegen            # writes priv/protos/**/*.proto + updates the lock
mix ash_grpc.codegen --check    # CI: fails on stale output or breaking changes
mix ash.codegen my_change       # also runs AshGrpc codegen (Ash extension codegen hook)
```

### 3.2 Consuming external services (connect)

```elixir
# one module per external service — as many as you need
defmodule MyApp.Billing do
  use AshGrpc.Client, otp_app: :my_app, services: [Billing.V1.BillingService]
end

defmodule MyApp.Search do
  use AshGrpc.Client, otp_app: :my_app, services: [Search.V2.SearchService]
end

# config/runtime.exs
config :my_app, MyApp.Billing,
  address: "dns:///billing.internal:50051",
  tls: [cacertfile: "...", certfile: "...", keyfile: "..."],   # or tls: false
  pool_size: 4,
  deadline: 5_000,
  retry: [max_attempts: 3, backoff: {:exponential, 50, 2_000}, on: [:unavailable]],
  metadata: {MyApp.Billing.Auth, :metadata, []},              # static map or MFA
  compression: :gzip,
  max_message_size: 4 * 1024 * 1024,
  interceptors: []

MyApp.Billing.call(:charge, %Billing.V1.ChargeRequest{amount: 100}, deadline: 1_000, actor: actor)
```

Foreign protos:

```shell
mix ash_grpc.import priv/protos/billing/**/*.proto -I priv/protos --module-prefix MyApp.Proto
# → lib/my_app/proto/**/*.pb.ex (compiled from the IR, same shape as protoc-gen-elixir)
```

or at compile time, without generated files in git:

```elixir
defmodule MyApp.Proto.Billing do
  use AshGrpc.Protos, files: ["priv/protos/billing/v1/billing.proto"], include: ["priv/protos"]
end
```

Use from Ash:

```elixir
# a single call as a generic action
action :charge, :struct do
  argument :amount, :integer, allow_nil?: false
  run {AshGrpc.Rpc, client: MyApp.Billing, rpc: :charge, request: &%{amount: &1.arguments.amount}}
end

# or a whole resource backed by a remote service
defmodule MyApp.Billing.Invoice do
  use Ash.Resource, domain: MyApp.Billing.Domain, data_layer: AshGrpc.DataLayer

  grpc_remote do
    client MyApp.Billing
    message Billing.V1.Invoice
    read :list_invoices, filter: [:customer_id], paginate: :page_token
    get :get_invoice, by: :id
    create :create_invoice
    update :update_invoice, update_mask: "update_mask"
    destroy :delete_invoice
  end
end
```

---

## 4. Protocol details (the important bits)

### 4.1 Naming (buf `STANDARD` lint compatible)

* package: `lower.snake.v1` (versioned; verifier warns on unversioned packages)
* messages / enums / services: `PascalCase`; services end with `Service`
* fields: `lower_snake_case` (Ash attribute names already are); `json_name` left default
* enum values: `UPPER_SNAKE`, prefixed with the enum name: `USER_ROLE_ADMIN`; `USER_ROLE_UNSPECIFIED = 0`
* rpc: `PascalCase` of the DSL name (`:get_user` → `GetUser`), request/response `GetUserRequest` /
  `GetUserResponse`. AIP standard methods return the resource message directly (`Get`, `Create`,
  `Update`), `List` returns `ListUsersResponse`, `Delete` returns `google.protobuf.Empty`.

### 4.2 Field numbers & compatibility

* Explicit `number:` always wins. Otherwise the number is taken from the lock, else the next free
  number (skipping 19000–19999 and reserved numbers) and written to the lock by codegen.
* Removing a field moves its number and name into `reserved` in the lock and in the `.proto`.
* Compile-time behaviour when the lock is stale: the endpoint still compiles with deterministic
  provisional numbers and emits a warning; `config :ash_grpc, require_lock?: true` (recommended
  for `:prod`) turns it into a compile error. `mix ash_grpc.codegen --check` is the CI gate.
* `Proto.Diff` breaking rules (subset of buf `WIRE_JSON`): field number changed/reused, type changed
  to an incompatible one, label changed (singular↔repeated), field/enum value removed without
  reservation, rpc removed/renamed, request/response type changed, streaming kind changed, package
  changed, enum value number changed.

### 4.3 Type mapping (defaults; override per field with `representation:` or per type with `AshGrpc.Type`)

| Ash type | proto | notes |
|---|---|---|
| `:string`, `:ci_string` | `string` | |
| `:integer` | `int64` | `constraints max <= 2^31` → may opt into `int32`; never `uint*` by default |
| `:float` | `double` | |
| `:decimal` | `string` | opt-in `google.type.Decimal`; never float |
| `:boolean` | `bool` | |
| `:uuid`, `:uuid_v7` | `string` | opt-in `bytes` (16) |
| `:binary` | `bytes` | |
| `:date` | `google.type.Date` | |
| `:time` | `google.type.TimeOfDay` | |
| `:utc_datetime(_usec)`, `:datetime` | `google.protobuf.Timestamp` | |
| `:naive_datetime` | `string` (ISO-8601) | no zone → no Timestamp |
| `:duration` | `google.protobuf.Duration` | |
| `:atom` + `one_of`, `Ash.Type.Enum` | `enum` with `*_UNSPECIFIED = 0` | `UNSPECIFIED` decodes to `nil` / validation error when required |
| `:map` (no fields) | `google.protobuf.Struct` | |
| `:map`/`:struct`/`:keyword`/`:tuple` with `fields` | nested message | |
| `Ash.Type.Union` | `oneof` inside a wrapper message | |
| embedded resource | message | |
| `{:array, t}` | `repeated t` | `{:array, t}` with `nil` items → wrapper message; array that can be nil vs empty → wrapper message only if `distinguish_nil?: true` |
| `:term`, `:function` | — | verifier error unless `representation:`/`AshGrpc.Type` given |

Presence: nullable scalars & enums are emitted as proto3 `optional` (explicit presence) so `nil` and
the zero value are distinguishable; required ones use implicit presence. Messages always have
presence. Inputs: an absent optional field means "not provided" (Ash default applies), never `nil`
— use the update mask (or a `google.protobuf.*Value` wrapper via `representation:`) to set `nil`.

### 4.4 Actions → rpcs

| kind | request | response | Ash call |
|---|---|---|---|
| `:get` (read) | `get_by` fields + arguments (+ `read_mask`) | resource message | `Ash.read_one` / `get?` → `NOT_FOUND` when nil |
| `:list` (read) | arguments + `page_size`, `page_token` (+ `filter`, `order_by` strings if `filter?: true`) | `List<Plural>Response { repeated items; next_page_token; optional total_size }` | keyset pagination, opaque base64 token |
| `:server_stream` (read) | arguments | `stream` resource message | `Ash.stream!/2` with backpressure |
| `:create` | accepted attributes + arguments (flat; `input: :wrapped` → `{ User user = 1; }`) | resource message | `Ash.create` |
| `:update` | primary key + accepted + arguments (+ `update_mask`) | resource message | `Ash.update` (atomic when possible) |
| `:destroy` | primary key + arguments | `google.protobuf.Empty` (or the record with `return_destroyed?: true`) | `Ash.destroy` |
| `:client_stream` (create) | `stream` create request | `<Rpc>Response { count; repeated errors }` | `Ash.bulk_create` |
| generic action | arguments | returns type; scalar returns wrapped in `<Rpc>Response { value }` | `Ash.run_action` |
| `:bidi_stream` | custom | custom | requires `handler:` (escape hatch) |

`request_message:` / `response_message:` rename or point to an external module; `handler:` replaces
the default handler entirely; `idempotency_level:` is derived (`read` → `NO_SIDE_EFFECTS`) and
overridable — the client only retries idempotent rpcs.

### 4.5 Errors

| Ash | gRPC status | details |
|---|---|---|
| `Ash.Error.Invalid` (input/changes) | `INVALID_ARGUMENT` | `google.rpc.BadRequest` with field violations (field path = proto field name) |
| `Ash.Error.Query.NotFound` | `NOT_FOUND` | `ResourceInfo` |
| `Ash.Error.Forbidden` | `PERMISSION_DENIED` | `ErrorInfo` (no policy breakdown unless configured) |
| unauthenticated (actor required) | `UNAUTHENTICATED` | |
| `Ash.Error.Changes.StaleRecord` | `ABORTED` | |
| unique constraint violation | `ALREADY_EXISTS` | |
| timeouts / deadline | `DEADLINE_EXCEEDED` | |
| `Ash.Error.Unknown` / anything else | `INTERNAL` | message hidden unless `show_raised_errors?: true` |

Extensible via the `AshGrpc.ToStatus` protocol (like `AshGraphql.Error`). The client maps statuses
back into Ash errors (`Ash.Error.Invalid` with field errors from `BadRequest`, etc.).

### 4.6 Metadata, auth, tenancy, deadlines

* Interceptors read metadata. `AshGrpc.Interceptors.Actor` calls a user behaviour
  (`AshGrpc.Actor.get_actor(metadata, stream) :: {:ok, actor | nil} | {:error, :unauthenticated}`);
  `AshGrpc.Interceptors.Tenant` reads `x-tenant` (configurable). Bearer tokens integrate with
  AshAuthentication in the guide.
* Incoming `grpc-timeout` becomes the Ash action timeout; the client always sends a deadline
  (default from config) and propagates the remaining deadline when called inside a server handler.
* Cancellation: client cancel stops server streams (`Ash.stream!` consumer exits).
* Message size limits, compression (gzip) and keepalive are configurable per endpoint/client.

### 4.7 Escape hatches

* `option` at file/message/field/service/rpc level (incl. custom `(my.ext).opt`)
* `representation:` per field, `AshGrpc.Type` per type
* `request_message:`/`response_message:` pointing to hand-written/imported modules
* `handler:` per rpc, raw `GRPC.Server` modules can be mounted in the endpoint next to generated ones
* the IR is public: `AshGrpc.Schema.build/2` → modify → `Render`/`Compiler`

---

## 5. Work plan

Phase 1 (parallel, independent files): **WP-A, WP-B, WP-C, WP-D, WP-E**.
Phase 2 (after phase 1 is merged): **WP-F server**, **WP-G codegen**, **WP-H remote**.
Phase 3: **WP-I docs, example app, end-to-end tests, CI**.

Rules for every package:

* touch only the files of your package (see module map); if you *must* change a shared file
  (`mix.exs`, `IR`, another package's stub), keep the change minimal and list it in the final report
* keep the contract signatures; if a contract is wrong, change it in one place and document it
* tests: `mix test`; quality gate: `mix check` (format, warnings-as-errors, credo, tests)
* docs: every public module has `@moduledoc`, every public function `@doc` + `@spec`

## 6. Known issues

* `cowlib 2.21.0` (transitive via `cowboy`/`gun`) has advisory EEF-CVE-2026-43966 (MEDIUM, HTTP
  response splitting in `cow_http_struct_hd`); no patched release yet — bump when available.
* `grpc` warns about missing `:gun` at compile time; AshGrpc clients default to the Mint adapter.
