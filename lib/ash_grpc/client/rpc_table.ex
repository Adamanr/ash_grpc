defmodule AshGrpc.Client.RpcTable do
  @moduledoc """
  Lookup table from the names a caller may use for an rpc to its definition.

  Built from `Service.__rpc_calls__/0` of every configured service (at compile time for
  `use AshGrpc.Client` modules, at start for dynamic clients). Every rpc is reachable by:

    * its proto name as atom or string: `:GetUser`, `"GetUser"`,
    * its snake_case name as atom or string: `:get_user`, `"get_user"`,
    * `{ServiceModule, name}` with any of the above names,
    * its full method path: `"/pkg.v1.UserService/GetUser"` or `"pkg.v1.UserService/GetUser"`.

  Names that exist in more than one service are ambiguous in the short forms; use the
  `{ServiceModule, name}` or path form for those.
  """

  defmodule Entry do
    @moduledoc "A resolved rpc."

    @typedoc """
    * `:service` - the `GRPC.Service` module
    * `:service_name` - fully qualified proto service name
    * `:name` - the proto rpc name as an atom (as in `__rpc_calls__/0`)
    * `:rpc` - the raw rpc tuple from `__rpc_calls__/0`
    * `:path` - `"/<service_name>/<name>"`
    * `:grpc_type` - `:unary | :client_stream | :server_stream | :bidirectional_stream`
    * `:request` / `:response` - message modules
    * `:idempotent?` - declared idempotent by the service descriptor
    """
    @type t :: %__MODULE__{
            service: module(),
            service_name: String.t(),
            name: atom(),
            rpc: tuple(),
            path: String.t(),
            grpc_type: :unary | :client_stream | :server_stream | :bidirectional_stream,
            request: module(),
            response: module(),
            idempotent?: boolean()
          }

    defstruct [
      :service,
      :service_name,
      :name,
      :rpc,
      :path,
      :grpc_type,
      :request,
      :response,
      idempotent?: false
    ]
  end

  @typedoc "The table: name keys to entries (or `{:ambiguous, [entry]}`)."
  @type t :: %{optional(term()) => Entry.t() | {:ambiguous, [Entry.t()]}}

  @doc "Builds the table for the given service modules."
  @spec build([module()]) :: t()
  def build(services) do
    services
    |> Enum.flat_map(&service_entries/1)
    |> Enum.flat_map(fn entry -> Enum.map(keys(entry), &{&1, entry}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {key, [entry]} -> {key, entry}
      {key, entries} -> {key, {:ambiguous, Enum.uniq(entries)}}
    end)
  end

  @doc "Resolves an rpc reference against the table."
  @spec fetch(t(), atom() | String.t() | {module(), atom() | String.t()}) ::
          {:ok, Entry.t()} | {:error, Exception.t()}
  def fetch(table, ref) do
    case Map.get(table, normalize(ref)) do
      %Entry{} = entry ->
        {:ok, entry}

      {:ambiguous, entries} ->
        {:error,
         ArgumentError.exception(
           "rpc #{inspect(ref)} is ambiguous, it exists in #{Enum.map_join(entries, ", ", &inspect(&1.service))}; " <>
             "use {Service, #{inspect(ref)}} or the full path"
         )}

      nil ->
        {:error, ArgumentError.exception("unknown rpc #{inspect(ref)}")}
    end
  end

  @doc "All distinct entries of the table."
  @spec entries(t()) :: [Entry.t()]
  def entries(table) when is_map(table) do
    table
    |> Map.values()
    |> Enum.flat_map(fn
      {:ambiguous, entries} -> entries
      entry -> [entry]
    end)
    |> Enum.uniq()
  end

  defp service_entries(service) do
    unless Code.ensure_loaded?(service) and function_exported?(service, :__rpc_calls__, 0) do
      raise ArgumentError, "#{inspect(service)} is not a GRPC.Service module"
    end

    service_name = service.__meta__(:name)

    Enum.map(service.__rpc_calls__(), fn {name, {req, _}, {res, _}, options} = rpc ->
      %Entry{
        service: service,
        service_name: service_name,
        name: name,
        rpc: rpc,
        path: "/#{service_name}/#{name}",
        grpc_type: GRPC.Service.grpc_type(rpc),
        request: req,
        response: res,
        idempotent?: idempotent_option?(options)
      }
    end)
  end

  defp keys(%Entry{} = entry) do
    names = [to_string(entry.name), Macro.underscore(to_string(entry.name))] |> Enum.uniq()

    Enum.flat_map(names, fn name -> [name, {entry.service, name}] end) ++
      [entry.path, String.trim_leading(entry.path, "/")]
  end

  defp normalize({service, name}) when is_atom(service), do: {service, to_string(name)}
  defp normalize(name) when is_atom(name), do: to_string(name)
  defp normalize(name) when is_binary(name), do: name
  defp normalize(other), do: other

  # Idempotency as declared in the method options. Accepted shapes (protoc-gen-elixir does not
  # emit it by default; AshGrpc's compiler does): `%{idempotency_level: level}` where level is
  # `:no_side_effects | :idempotent | :NO_SIDE_EFFECTS | :IDEMPOTENT`, possibly wrapped as
  # `%{value: level}`, or a `Google.Protobuf.MethodOptions` struct under `:options`.
  defp idempotent_option?(options) when is_map(options) do
    level =
      case Map.get(options, :idempotency_level) do
        %{value: value} -> value
        value when not is_nil(value) -> value
        nil -> options |> Map.get(:options) |> method_options_level()
      end

    level in [:no_side_effects, :idempotent, :NO_SIDE_EFFECTS, :IDEMPOTENT, 1, 2]
  end

  defp idempotent_option?(_), do: false

  defp method_options_level(%{idempotency_level: level}), do: level
  defp method_options_level(_), do: nil
end
