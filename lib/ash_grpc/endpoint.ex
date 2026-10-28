defmodule AshGrpc.Endpoint do
  @moduledoc """
  A gRPC endpoint serving the rpcs of Ash domains (`grpc do ... end` in resources and domains).

      defmodule MyApp.GrpcEndpoint do
        use AshGrpc.Endpoint,
          otp_app: :my_app,
          domains: [MyApp.Accounts],
          interceptors: [
            AshGrpc.Interceptors.Logger,
            {AshGrpc.Interceptors.Actor, from: MyApp.Grpc.Auth},
            AshGrpc.Interceptors.Tenant
          ],
          reflection: true,
          health: true
      end

      # application.ex
      children = [{AshGrpc.Server, endpoint: MyApp.GrpcEndpoint, port: 50051}]

  At compile time the endpoint

    1. loads the field-number lock (`lock_path`, tracked as `@external_resource`) and builds
       the schema with `AshGrpc.Schema.build_with_lock/2`. When the lock is missing or stale
       the endpoint still compiles with provisional numbers and emits a warning;
       `config :ash_grpc, require_lock?: true` (or `require_lock?: true`) turns that into a
       compile error (see DESIGN.md §4.2; `mix ash_grpc.codegen` updates the lock),
    2. defines the message, enum, service and stub modules of the schema
       (`AshGrpc.Proto.Compiler.quoted/2`, so they are real `.beam` files),
    3. defines one `GRPC.Server` module per service (`<Endpoint>.Servers.<ServiceName>`) whose
       functions call `AshGrpc.Server.Handler`,
    4. defines reflection servers (when `reflection` is enabled) and mounts the health
       service (`AshGrpc.Server.Health`),
    5. is a `GRPC.Endpoint` with the given interceptors.

  The endpoint depends on its domains and resources at compile time, so changing them
  recompiles it.

  The schema's modules are global: serve a domain from one endpoint only.

  ## Options

    * `:otp_app` – the application (required)
    * `:domains` – Ash domains using `AshGrpc.Domain` (required)
    * `:interceptors` – `GRPC.Server.Interceptor`s, `module` or `{module, opts}`, run in order
      (e.g. `AshGrpc.Interceptors.Logger`, `AshGrpc.Interceptors.Actor`,
      `AshGrpc.Interceptors.Tenant`)
    * `:servers` – extra hand-written `GRPC.Server` modules to mount
    * `:reflection` – `true` (v1 and v1alpha), `:v1`, `:v1alpha` or `false` (default); requires
      the optional `grpc_reflection` dependency
    * `:health` – serve `grpc.health.v1.Health` (default `true`)
    * `:lock_path` – default `AshGrpc.Proto.Lock.default_path/1`
    * `:require_lock?` – overrides `config :ash_grpc, :require_lock?`
    * `:show_raised_errors?` – include messages of internal errors in statuses (default:
      `config :ash_grpc, :show_raised_errors?`, `false`)
    * `:max_message_size` – max request size in bytes (default 4 MiB), used by `AshGrpc.Server`
    * `:compressors` – response compressors (default `[GRPC.Compressor.Gzip]`; a compressor is
      used when the client asks for it)
    * `:default_page_size` / `:max_page_size` – `:list` page sizes (defaults: the action's
      `default_limit` or 50 / the action's `max_page_size` or 1000)
    * `:stream_batch_size` – batch size of `Ash.stream!/2` for server streams and of
      `Ash.bulk_create/4` for client streams (default 100)

  ## Functions

    * `schema/0` – the `AshGrpc.Proto.IR.Schema` served by the endpoint
    * `__meta__/1` – `GRPC.Endpoint` metadata
  """

  @doc false
  defmacro __using__(opts) do
    AshGrpc.Server.Builder.endpoint(opts, __CALLER__)
  end
end
