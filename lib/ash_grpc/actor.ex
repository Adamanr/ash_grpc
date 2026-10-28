defmodule AshGrpc.Actor do
  @moduledoc """
  Behaviour for resolving the Ash actor of an incoming gRPC request.

  Used by `AshGrpc.Interceptors.Actor`:

      defmodule MyApp.Grpc.Auth do
        @behaviour AshGrpc.Actor

        @impl true
        def get_actor(metadata, _stream) do
          case metadata["authorization"] do
            nil -> {:ok, nil}
            "Bearer " <> token -> MyApp.Accounts.user_from_token(token)
            _ -> {:error, :unauthenticated}
          end
        end
      end

      use AshGrpc.Endpoint,
        otp_app: :my_app,
        domains: [MyApp.Accounts],
        interceptors: [{AshGrpc.Interceptors.Actor, from: MyApp.Grpc.Auth}]

  `metadata` is the map of request headers (lowercase keys, `-bin` headers decoded).

  Return `{:ok, nil}` for anonymous requests (policies decide what they may do) and
  `{:error, :unauthenticated}` (or any `{:error, exception}`) to reject the request with
  `UNAUTHENTICATED` (or the status of the exception, see `AshGrpc.Error`).
  """

  @doc "Resolves the actor from the request metadata."
  @callback get_actor(metadata :: %{String.t() => String.t()}, stream :: GRPC.Server.Stream.t()) ::
              {:ok, term() | nil} | {:error, :unauthenticated | Exception.t() | term()}
end
