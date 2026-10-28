# Auth, tenancy and interceptors

Endpoints run `GRPC.Server.Interceptor`s in order before the default handler. AshGrpc ships
three of them. Each request carries its actor, tenant and extra Ash context through to every
Ash call, so policies, multitenancy and field policies apply exactly as they do elsewhere in
your app.

```elixir
defmodule MyApp.GrpcEndpoint do
  use AshGrpc.Endpoint,
    otp_app: :my_app,
    domains: [MyApp.Accounts],
    interceptors: [
      AshGrpc.Interceptors.Logger,
      {AshGrpc.Interceptors.Actor, from: MyApp.Grpc.Auth},
      {AshGrpc.Interceptors.Tenant, header: "x-org"}
    ]
end
```

## The actor

Implement `AshGrpc.Actor` to turn request metadata (lowercase header keys) into an actor:

```elixir
defmodule MyApp.Grpc.Auth do
  @behaviour AshGrpc.Actor

  @impl true
  def get_actor(metadata, _stream) do
    case metadata["authorization"] do
      nil -> {:ok, nil}                                   # anonymous: policies decide
      "Bearer " <> token -> MyApp.Accounts.user_from_token(token)
      _ -> {:error, :unauthenticated}                     # rejected with UNAUTHENTICATED
    end
  end
end
```

`{AshGrpc.Interceptors.Actor, from: MyApp.Grpc.Auth, required?: true}` rejects anonymous
requests outright. With `required?: false` (the default) the actor is `nil`, and your policies
decide what anonymous callers may do. A missing actor that a policy needs yields
`PERMISSION_DENIED` or `UNAUTHENTICATED`.

### With AshAuthentication

Bearer tokens issued by AshAuthentication can be verified in `get_actor/2`:

```elixir
def get_actor(%{"authorization" => "Bearer " <> token}, _stream) do
  case AshAuthentication.Jwt.verify(token, :my_app) do
    {:ok, %{"sub" => subject}, _resource} ->
      AshAuthentication.subject_to_user(subject, MyApp.Accounts.User)

    _ ->
      {:error, :unauthenticated}
  end
end

def get_actor(_metadata, _stream), do: {:ok, nil}
```

Check the token-revocation and purpose settings of your strategy in the AshAuthentication
docs.

### Propagating the actor to another service

On the calling side, a client's `metadata` function receives the call options, including the
`:actor` that `AshGrpc.Rpc` and `AshGrpc.DataLayer` pass. Turn it into the header that the
remote `AshGrpc.Actor` expects:

```elixir
defmodule MyApp.LibraryClient do
  use AshGrpc.Client, otp_app: :my_app, services: [Library.V1.LibraryService.Service]

  @impl AshGrpc.Client
  def init(config), do: {:ok, Keyword.put(config, :metadata, &__MODULE__.metadata/1)}

  def metadata(%{opts: opts}) do
    case opts[:actor] do
      %{id: id} -> %{"authorization" => "Bearer " <> MyApp.Tokens.for_service(id)}
      _ -> %{}
    end
  end
end
```

`Ash.read!(RemoteNote, actor: alice)` then reaches the server as alice, and the server's
policies filter and authorize as if she called it directly.

## Tenancy

`AshGrpc.Interceptors.Tenant` reads the tenant from a header (`x-tenant` by default) and passes
it as `tenant:` to every Ash call:

```elixir
{AshGrpc.Interceptors.Tenant, header: "x-org", required?: true, parse: {MyApp.Grpc, :parse_org}}
```

`parse:` is called as `MyApp.Grpc.parse_org(value, stream)` and returns `{:ok, tenant}` or
`{:error, error}`. Resources using attribute or context multitenancy work unchanged.

## Logging and telemetry

`AshGrpc.Interceptors.Logger` logs one line per rpc:

```text
[info] GRPC /myapp.accounts.v1.AccountsService/GetUser -> OK in 1.2ms
```

Pass `level:` to change the level of successful calls and `error_level:` for failed ones.
Every rpc also emits `[:ash_grpc, :server, :rpc, :start | :stop | :exception]` telemetry,
whatever interceptors are configured.

Deliberate statuses (`INVALID_ARGUMENT`, `NOT_FOUND`, …) are not logged as server errors.
Internal errors are logged by the handler with their stacktrace (`AshGrpc.Server.log_exception?/1`).

## Writing your own interceptor

Interceptors are plain `GRPC.Server.Interceptor`s. Use `AshGrpc.Server.put_actor/2`,
`put_tenant/2` and `put_context/2` to hand values to the Ash calls of the request:

```elixir
defmodule MyApp.Grpc.RequestId do
  @behaviour GRPC.Server.Interceptor
  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(request, stream, next, _opts) do
    request_id = GRPC.Stream.get_headers(stream)["x-request-id"] || Ecto.UUID.generate()
    Logger.metadata(request_id: request_id)
    next.(request, AshGrpc.Server.put_context(stream, %{request_id: request_id}))
  end
end
```

## TLS

```elixir
{AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 50051,
 tls: [certfile: "priv/cert.pem", keyfile: "priv/key.pem"]}
```

On the client side, `tls: true` verifies against the OS trust store. Pass ssl options for a
custom CA or for mTLS (`cacertfile`, `certfile`, `keyfile`).
