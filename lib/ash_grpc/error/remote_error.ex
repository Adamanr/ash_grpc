defmodule AshGrpc.Error.RemoteError do
  @moduledoc """
  An error returned by a remote gRPC service (built by `AshGrpc.Error.from_rpc_error/2`).

  Fields:

    * `code` – status code atom (`:permission_denied`, `:unavailable`, …)
    * `status` – status number
    * `message` – the status message sent by the server
    * `reason`, `domain`, `metadata` – from `google.rpc.ErrorInfo`
    * `resource_info` – from `google.rpc.ResourceInfo` (map)
    * `details` – all decoded detail messages (unknown ones stay `Google.Protobuf.Any`)

  The Splode `class` is set from the status code (`:invalid`, `:forbidden` or `:unknown`).
  """

  use Splode.Error,
    fields: [
      :code,
      :status,
      :message,
      :reason,
      :domain,
      :resource_info,
      metadata: %{},
      details: []
    ],
    class: :unknown

  @impl true
  def message(%{code: code, message: message}) when message in [nil, ""],
    do: "remote gRPC error: #{code}"

  def message(%{code: code, message: message}), do: "remote gRPC error (#{code}): #{message}"
end
