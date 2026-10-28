defmodule AshGrpc.Interceptors.Actor do
  @moduledoc """
  Server interceptor that resolves the Ash actor of a request from its metadata, using a module
  implementing `AshGrpc.Actor`.

      use AshGrpc.Endpoint,
        otp_app: :my_app,
        domains: [MyApp.Accounts],
        interceptors: [{AshGrpc.Interceptors.Actor, from: MyApp.Grpc.Auth, required?: true}]

  The actor is passed to every Ash call of the request (`actor:`), so policies apply.

  ## Options

    * `:from` – the `AshGrpc.Actor` module (required)
    * `:required?` – reject requests without an actor with `UNAUTHENTICATED` (default `false`)

  `{:error, :unauthenticated}` from the actor module always rejects the request with
  `UNAUTHENTICATED`; other `{:error, error}` values are converted with `AshGrpc.Error`.
  """

  @behaviour GRPC.Server.Interceptor

  alias AshGrpc.Error.Unauthenticated

  @impl true
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts) do
    opts = Keyword.validate!(opts, [:from, required?: false])

    case opts[:from] do
      module when is_atom(module) and not is_nil(module) ->
        [from: module, required?: opts[:required?]]

      other ->
        raise ArgumentError,
              "AshGrpc.Interceptors.Actor requires `from: module` (an AshGrpc.Actor), got: #{inspect(other)}"
    end
  end

  @impl true
  def call(request, stream, next, opts) do
    metadata = AshGrpc.Server.Context.metadata(stream)

    case opts[:from].get_actor(metadata, stream) do
      {:ok, nil} ->
        if opts[:required?], do: unauthenticated!(), else: next.(request, stream)

      {:ok, actor} ->
        next.(request, AshGrpc.Server.put_actor(stream, actor))

      {:error, :unauthenticated} ->
        unauthenticated!()

      {:error, error} ->
        raise AshGrpc.Error.to_rpc_error(error)
    end
  end

  defp unauthenticated!, do: raise(AshGrpc.Error.to_rpc_error(Unauthenticated.exception([])))
end
