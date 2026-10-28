# Escape hatches

AshGrpc's defaults are meant to cover most APIs, and every level can be overridden. The list
below goes from the smallest change to the largest.

## Field level

```elixir
grpc do
  field :id, number: 1                                   # pin a number explicitly
  field :inserted_at, representation: :string            # ISO-8601 instead of Timestamp
  field :price, representation: {:message, "google.type.Decimal"}
  field :admin?, proto_name: "is_admin"
  field :email, json_name: "emailAddress", deprecated?: true,
    options: [{"(my.ext).pii", true}]
  reserved numbers: [4, 10..12], names: ["legacy_name"]
end
```

The `representation:` choices of every type are listed in `AshGrpc.Type.Mapping`.

## Type level: `AshGrpc.Type`

To give a custom Ash type its own protobuf representation, implement `AshGrpc.Type`:

```elixir
defmodule MyApp.Types.Money do
  use Ash.Type.NewType, subtype_of: :map, constraints: [fields: [amount: [type: :integer], currency: [type: :string]]]
  @behaviour AshGrpc.Type

  @impl AshGrpc.Type
  def proto_type(_constraints) do
    {:ok, %AshGrpc.Type.Mapping.Result{type: {:message, "google.type.Money"},
                                        imports: ["google/type/money.proto"]}}
  end

  @impl AshGrpc.Type
  def encode_proto(%{amount: cents, currency: currency}, _constraints),
    do: {:ok, %Google.Type.Money{currency_code: currency, units: div(cents, 100), nanos: rem(cents, 100) * 10_000_000}}

  @impl AshGrpc.Type
  def decode_proto(%Google.Type.Money{} = money, _constraints),
    do: {:ok, %{amount: money.units * 100 + div(money.nanos, 10_000_000), currency: money.currency_code}}
end
```

## Options at every level

`option` exists on domains (file options), messages, fields, services and rpcs. It accepts
standard options and custom extensions (`"(my.ext).opt"`):

```elixir
# domain
grpc do
  option :go_package, "github.com/acme/myapp/gen/accounts/v1;accountsv1"
  option :java_multiple_files, true
  imports ["validate/validate.proto"]
end

# rpc
rpc :get_user, :read, kind: :get, options: [{"(google.api.http).get", "/v1/users/{id}"}]
```

Custom options are rendered into the `.proto` files. They are not encoded into the runtime
descriptors that reflection serves.

## Messages

* `request_message: "LookupUserRequest"` renames a generated request message.
* `request_message: MyApp.Proto.LegacyRequest` (a `use Protobuf` module) replaces it. Add its
  file to the domain's `imports`. A handwritten response message needs a `handler:`.
* `input: :wrapped` sends the record as one field (`{ User user = 1; ... }`) instead of flat
  fields.
* `load:` sets what is loaded on returned records (by default, the calculations and
  aggregates listed in `fields`).

## Rpc level: `handler:`

```elixir
rpc :sync, :read, kind: :bidi_stream, handler: MyApp.Grpc.SyncHandler
```

```elixir
defmodule MyApp.Grpc.SyncHandler do
  @behaviour AshGrpc.Server.RpcHandler

  @impl true
  def handle_rpc(requests, stream, ctx) do
    Enum.each(requests, fn request ->
      record = Ash.get!(ctx.resource, request.id, actor: ctx.actor, tenant: ctx.tenant)
      {:ok, reply} = AshGrpc.Server.Handler.encode_record(record, ctx)
      GRPC.Server.send_reply(stream, reply)
    end)
  end
end
```

The handler runs inside the endpoint's interceptors and telemetry, with the actor, tenant and
deadline of the request. Returned or raised errors go through `AshGrpc.Error.to_rpc_error/2`.
See `AshGrpc.Server.RpcHandler`.

## Endpoint level: hand-written servers

Mount any `GRPC.Server` next to the generated ones:

```elixir
use AshGrpc.Endpoint,
  otp_app: :my_app,
  domains: [MyApp.Accounts],
  servers: [MyApp.Grpc.LegacyServer]
```

## Errors

Implement `AshGrpc.ToStatus` for your own exceptions to choose the status code, the public
message and the `ErrorInfo` reason and metadata:

```elixir
defimpl AshGrpc.ToStatus, for: MyApp.Errors.QuotaExceeded do
  def to_status(error) do
    %AshGrpc.Error.Info{code: :resource_exhausted, message: "quota exceeded", public?: true,
                        reason: "QUOTA_EXCEEDED", metadata: %{"limit" => to_string(error.limit)}}
  end
end
```

## The IR

Everything goes through one intermediate representation, `AshGrpc.Proto.IR`. You can build it,
change it, and render or compile it yourself:

```elixir
{:ok, schema} = AshGrpc.Schema.build([MyApp.Accounts], [])
schema = put_in_my_custom_options(schema)
for file <- schema.files, do: IO.puts(AshGrpc.Proto.Render.render(file, []))
AshGrpc.Proto.Compiler.compile(schema, [])
```

Foreign protos land in the same IR (`AshGrpc.Proto.Import.from_files/2`), so they can be
inspected, diffed (`AshGrpc.Proto.Diff.diff/2`) and re-rendered the same way.

## Clients

* `MyClient.channel/1` returns a connected `GRPC.Channel` to use with generated stubs directly.
* Client `interceptors:`, `adapter:` and `adapter_opts:`, a custom `codec:`, and
  `map_errors: false` for raw `GRPC.RPCError`s.
* `AshGrpc.Rpc` with `request:`/`response:` functions, for rpcs whose shapes don't map
  one-to-one to an action.
