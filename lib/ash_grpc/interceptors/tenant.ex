defmodule AshGrpc.Interceptors.Tenant do
  @moduledoc """
  Server interceptor that reads the Ash tenant of a request from a metadata header
  (`x-tenant` by default) and passes it to every Ash call (`tenant:`).

      interceptors: [{AshGrpc.Interceptors.Tenant, header: "x-org", required?: true}]

  ## Options

    * `:header` – metadata key (default `"x-tenant"`, lowercase)
    * `:required?` – reject requests without the header with `INVALID_ARGUMENT` (default `false`)
    * `:parse` – `{module, function}` called as `module.function(value, stream)`; returns
      `{:ok, tenant}` or `{:error, error}` (converted with `AshGrpc.Error`). Defaults to the raw
      string value.
  """

  @behaviour GRPC.Server.Interceptor

  @impl true
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts) do
    opts = Keyword.validate!(opts, header: "x-tenant", required?: false, parse: nil)

    case opts[:parse] do
      nil -> :ok
      {module, function} when is_atom(module) and is_atom(function) -> :ok
      other -> raise ArgumentError, "invalid :parse option #{inspect(other)}"
    end

    [header: String.downcase(opts[:header]), required?: opts[:required?], parse: opts[:parse]]
  end

  @impl true
  def call(request, stream, next, opts) do
    case Map.get(AshGrpc.Server.Context.metadata(stream), opts[:header]) do
      value when value in [nil, ""] ->
        if opts[:required?] do
          raise GRPC.RPCError,
            status: GRPC.Status.invalid_argument(),
            message: "missing #{opts[:header]} metadata"
        end

        next.(request, stream)

      value ->
        next.(request, AshGrpc.Server.put_tenant(stream, parse(value, stream, opts[:parse])))
    end
  end

  defp parse(value, _stream, nil), do: value

  defp parse(value, stream, {module, function}) do
    case apply(module, function, [value, stream]) do
      {:ok, tenant} -> tenant
      {:error, error} -> raise AshGrpc.Error.to_rpc_error(error)
    end
  end
end
