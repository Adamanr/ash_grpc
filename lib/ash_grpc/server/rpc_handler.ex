defmodule AshGrpc.Server.RpcHandler do
  @moduledoc """
  Escape hatch: handle an rpc yourself instead of the default handler (`handler:` rpc option;
  required for `:bidi_stream`).

      rpc :sync, :read, kind: :bidi_stream, handler: MyApp.Grpc.SyncHandler

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

  `request` is the decoded request struct, or an enumerable of them for client and
  bidirectional streaming. Unary and client-streaming rpcs return the response struct
  (or `{:ok, response}`); server-streaming rpcs send replies with `GRPC.Server.send_reply/2`
  and their return value is ignored. Return `{:error, error}` or raise to fail the rpc: errors
  are converted with `AshGrpc.Error.to_rpc_error/2`.

  The handler runs inside the endpoint's interceptors and telemetry span, with the incoming
  deadline propagated to `AshGrpc.Client` calls.
  """

  @doc "Handles one rpc call."
  @callback handle_rpc(
              request :: struct() | Enumerable.t(),
              stream :: GRPC.Server.Stream.t(),
              context :: AshGrpc.Server.Context.t()
            ) :: struct() | {:ok, struct()} | {:error, term()} | term()
end
