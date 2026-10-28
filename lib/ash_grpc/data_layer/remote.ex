defmodule AshGrpc.DataLayer.Remote do
  @moduledoc """
  Calls of external rpcs on behalf of Ash actions, shared by `AshGrpc.DataLayer` and
  `AshGrpc.Rpc`.

  Every call is made with:

    * `actor:` and `tenant:` call options, available to the client's `:metadata` function
      (see `AshGrpc.Client.Call`),
    * the metadata computed by the `metadata` option (a map, a function of the call context or
      `{m, f, a}` called with the context as first argument),
    * `deadline:` when one is known,
    * `map_errors: false`: `GRPC.RPCError`s are mapped here, with the resource and request
      message of the call (`map_error/2`).
  """

  alias AshGrpc.Proto.IR

  @typedoc """
  The context of a call: `:actor`, `:tenant`, `:resource`, `:action` (name), `:context` (the
  action context), `:deadline` (ms or `nil`) and `:metadata` (the metadata option).
  """
  @type context :: %{
          optional(:actor) => term(),
          optional(:tenant) => term(),
          optional(:resource) => module() | nil,
          optional(:action) => atom() | nil,
          optional(:context) => map(),
          optional(:deadline) => pos_integer() | nil,
          optional(:metadata) => term()
        }

  @doc "Calls the unary `rpc` of `client`. Errors are returned unmapped (see `map_error/2`)."
  @spec call(AshGrpc.Client.client(), AshGrpc.Client.rpc(), struct(), context()) ::
          {:ok, struct()} | {:error, GRPC.RPCError.t() | Exception.t()}
  def call(client, rpc, request, context) do
    case AshGrpc.Client.call(client, rpc, request, call_opts(context)) do
      {:ok, response} -> {:ok, response}
      {:ok, response, _headers} -> {:ok, response}
      {:error, error} -> {:error, error}
    end
  end

  @doc "The client call options for `context` (see the module docs)."
  @spec call_opts(context()) :: Keyword.t()
  def call_opts(context) do
    meta_context = %{
      actor: context[:actor],
      tenant: context[:tenant],
      resource: context[:resource],
      action: context[:action],
      context: context[:context] || %{}
    }

    [
      actor: context[:actor],
      tenant: context[:tenant],
      metadata: metadata(context[:metadata], meta_context),
      map_errors: false
    ]
    |> then(fn opts ->
      case context[:deadline] do
        deadline when is_integer(deadline) -> Keyword.put(opts, :deadline, deadline)
        _ -> opts
      end
    end)
  end

  defp metadata(nil, _context), do: %{}
  defp metadata(map, _context) when is_map(map), do: map
  defp metadata(fun, context) when is_function(fun, 1), do: fun.(context) || %{}
  defp metadata({m, f, a}, context), do: apply(m, f, [context | a]) || %{}

  @doc """
  Maps a call error into an Ash error.

  `GRPC.RPCError`s go through `AshGrpc.Error.from_rpc_error/2`. Options:

    * `:message` – the bound `IR.Message` of the request (proto → Ash field names),
    * `:resource`, `:primary_key` – for `Ash.Error.Query.NotFound`,
    * `:wrapper` – name of the request field holding the record: field violations under it
      (`ticket.title`) are reported on the record's fields,
    * `:names` – proto field name => Ash name of the record's fields (used with `:wrapper`).
  """
  @spec map_error(term(), Keyword.t()) :: Exception.t()
  def map_error(%GRPC.RPCError{} = error, opts) do
    error
    |> AshGrpc.Error.from_rpc_error(Keyword.take(opts, [:message, :resource, :primary_key]))
    |> remap_fields(opts[:wrapper], opts[:names] || %{})
  end

  def map_error(error, _opts) when is_exception(error), do: error
  def map_error(error, _opts), do: Ash.Error.to_ash_error(error)

  defp remap_fields(error, nil, _names), do: error

  defp remap_fields(%{errors: errors} = error, wrapper, names) when is_list(errors) do
    wrapper = to_string(wrapper)

    %{
      error
      | errors:
          Enum.map(errors, fn
            %Ash.Error.Changes.InvalidAttribute{path: [first | rest], field: field} = invalid ->
              if to_string(first) == wrapper do
                %{invalid | path: rest, field: rename(field, rest, names)}
              else
                invalid
              end

            other ->
              other
          end)
    }
  end

  defp remap_fields(error, _wrapper, _names), do: error

  defp rename(field, [], names), do: Map.get(names, to_string(field), field)
  defp rename(field, _path, _names), do: field

  @doc """
  The request message of `module` bound to the given specs, for error mapping (`:message` of
  `map_error/2`), or `nil` when its IR is not available.
  """
  @spec bound_message(module(), [AshGrpc.DataLayer.Mapping.spec()]) :: IR.Message.t() | nil
  def bound_message(module, specs) do
    case AshGrpc.DataLayer.Foreign.message(module) do
      {:ok, message, schema} ->
        {message, _schema} = AshGrpc.DataLayer.Mapping.bind(message, schema, specs)
        message

      {:error, _} ->
        nil
    end
  end
end
