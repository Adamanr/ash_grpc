# Rules for working with AshGrpc

## Understanding AshGrpc

AshGrpc adds gRPC to Ash in two directions. **Serving** exposes Ash actions as gRPC rpcs with
the `grpc` DSL of `AshGrpc.Resource` and `AshGrpc.Domain`, served by a `use AshGrpc.Endpoint`
module under `AshGrpc.Server`. **Consuming** calls external services through
`use AshGrpc.Client` modules, from generic actions (`AshGrpc.Rpc`) or from resources whose
data layer is `AshGrpc.DataLayer`. Read the guides in `documentation/topics` before using a
feature; do not guess option names.

## Serving

- Add `extensions: [AshGrpc.Resource]` to resources and `extensions: [AshGrpc.Domain]` to their
  domain. Set a versioned `package` in the domain (`"myapp.accounts.v1"`).
- Declare one `rpc :name, :action` per exposed action. Leave `kind` out unless you need a
  streaming kind (`:server_stream`, `:client_stream`, `:bidi_stream`), which is always explicit.
- List the message fields with `fields [...]`. Only public attributes are included by default;
  calculations, aggregates and relationships must be listed.
- Use `update_mask?: true` on update rpcs that clients call with partial data, and
  `read_mask?: true` / `filter?: true` only where clients need them.
- Serve a domain from exactly one endpoint. Start it with
  `{AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 50051}`.
- Put authentication in an `AshGrpc.Actor` module used by `AshGrpc.Interceptors.Actor`. Do not
  read metadata in actions. Authorization belongs in Ash policies.
- Never return internal error messages to clients. Leave `show_raised_errors?` off outside
  development, and use `AshGrpc.ToStatus` for errors that must be public.

## Field numbers and compatibility

- After every change to a served resource or domain, run `mix ash_grpc.codegen` (or
  `mix ash.codegen`). Commit the `.proto` files, `priv/grpc/ash_grpc.lock.json` and
  `priv/grpc/snapshots`.
- Never edit the lock or the generated `.proto` files by hand. Never reuse a removed field
  name: it is reserved on purpose.
- Run `mix ash_grpc.codegen --check` in CI. Pass `--allow-breaking` only when a wire-breaking
  change is intended and every client is coordinated.
- Set `config :ash_grpc, require_lock?: true` in production.
- Do not pass `number:` unless you must match an existing contract. The lock assigns stable
  numbers.

## Consuming

- Define one `use AshGrpc.Client, otp_app: ..., services: [...]` module per external service
  and add it to the supervision tree. Configure `address`, `tls` and `deadline` in
  `config/runtime.exs`.
- Get protobuf modules for foreign services from `use AshGrpc.Protos` or
  `mix ash_grpc.import`. Do not hand-write protobuf modules for a service that has `.proto`
  files.
- Retries only apply to idempotent rpcs. Mark rpcs as `idempotent:` in the client config only
  when repeating them is safe.
- Propagate the actor through the client's `metadata` function (`opts[:actor]`). Do not put
  tokens into requests.
- Use `AshGrpc.Rpc` for single calls in generic actions. Use `AshGrpc.DataLayer` when the
  remote service owns a resource (CRUD rpcs). Remote resources have no transactions.
- List the attributes whose equality filters the remote list rpc supports in `read ...,
  filter: [...]`. Other filters run in memory after all pages are fetched, so prefer
  pushed-down filters on large collections.

## Testing

- Use `config :my_app, MyClient, sandbox: true` in `config/test.exs` and
  `AshGrpc.Client.Sandbox.expect/4` / `stub/3` for code that calls other services.
- Test your own API end to end with `{AshGrpc.Server, endpoint: ..., port: 0}`,
  `AshGrpc.Server.port/1` and a client. Handlers run in their own processes, so data must be
  visible to them (no `ets private?: true`, shared Ecto sandbox).

## Never

- Never use `String.to_atom/1` on wire data.
- Never call `GRPC.Stub` directly when a client module exists; `MyClient.channel/1` is the
  escape hatch.
