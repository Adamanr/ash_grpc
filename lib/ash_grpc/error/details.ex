defmodule AshGrpc.Error.Details do
  @moduledoc """
  Packs and unpacks `google.rpc.*` error details as `google.protobuf.Any`.

  `GRPC.RPCError.details` is the list of `Any` messages of the
  `google.rpc.Status` carried in the `grpc-status-details-bin` trailer: the
  server adapter encodes it, the client adapters decode it.

  The `googleapis` modules do not define `full_name/0`, so `Protobuf.Any.pack/1`
  can not be used for them; type URLs are mapped explicitly here (and never
  turned into atoms).
  """

  @prefix "type.googleapis.com/"

  @types %{
    "google.rpc.BadRequest" => Google.Rpc.BadRequest,
    "google.rpc.ErrorInfo" => Google.Rpc.ErrorInfo,
    "google.rpc.ResourceInfo" => Google.Rpc.ResourceInfo,
    "google.rpc.DebugInfo" => Google.Rpc.DebugInfo,
    "google.rpc.RetryInfo" => Google.Rpc.RetryInfo,
    "google.rpc.QuotaFailure" => Google.Rpc.QuotaFailure,
    "google.rpc.PreconditionFailure" => Google.Rpc.PreconditionFailure,
    "google.rpc.RequestInfo" => Google.Rpc.RequestInfo,
    "google.rpc.Help" => Google.Rpc.Help,
    "google.rpc.LocalizedMessage" => Google.Rpc.LocalizedMessage
  }

  @names Map.new(@types, fn {name, module} -> {module, name} end)

  @doc "Packs a detail message into `google.protobuf.Any`."
  @spec pack(struct()) :: Google.Protobuf.Any.t()
  def pack(%module{} = detail) do
    name =
      Map.get_lazy(@names, module, fn ->
        if function_exported?(module, :full_name, 0),
          do: module.full_name(),
          else: raise(ArgumentError, "unknown error detail type #{inspect(module)}")
      end)

    %Google.Protobuf.Any{type_url: @prefix <> name, value: module.encode(detail)}
  end

  @doc """
  Unpacks a detail. Unknown or undecodable details are returned unchanged.
  """
  @spec unpack(Google.Protobuf.Any.t() | struct()) :: struct()
  def unpack(%Google.Protobuf.Any{type_url: type_url, value: value} = any) do
    with name when is_binary(name) <- type_name(type_url),
         {:ok, module} <- Map.fetch(@types, name) do
      try do
        module.decode(value)
      rescue
        _ -> any
      end
    else
      _ -> any
    end
  end

  def unpack(detail), do: detail

  @doc "Unpacks all details of a `GRPC.RPCError` (`nil` → `[]`)."
  @spec unpack_all([Google.Protobuf.Any.t()] | nil) :: [struct()]
  def unpack_all(nil), do: []
  def unpack_all(details) when is_list(details), do: Enum.map(details, &unpack/1)

  defp type_name(type_url) do
    case String.split(type_url, "/") do
      [_ | _] = parts when length(parts) > 1 -> List.last(parts)
      _ -> nil
    end
  end
end
