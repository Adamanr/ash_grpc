defmodule AshGrpc.Client.Errors do
  @moduledoc """
  Normalizes everything that can go wrong in a client call into exceptions.

  * `normalize/1` turns transport failures, exits and raw terms into `GRPC.RPCError`s with a
    meaningful status (a closed connection becomes `UNAVAILABLE`, not `UNKNOWN`), so that retry
    decisions and telemetry can rely on the status code.
  * `from_rpc_error/2` maps a `GRPC.RPCError` into the Ash error returned to the caller via
    `AshGrpc.Error.from_rpc_error/2`.
  """

  @status_names %{
    0 => :ok,
    1 => :cancelled,
    2 => :unknown,
    3 => :invalid_argument,
    4 => :deadline_exceeded,
    5 => :not_found,
    6 => :already_exists,
    7 => :permission_denied,
    8 => :resource_exhausted,
    9 => :failed_precondition,
    10 => :aborted,
    11 => :out_of_range,
    12 => :unimplemented,
    13 => :internal,
    14 => :unavailable,
    15 => :data_loss,
    16 => :unauthenticated
  }

  @codes Map.new(@status_names, fn {code, name} -> {name, code} end)

  @doc "The snake_case name of a gRPC status code (`14` → `:unavailable`)."
  @spec status_name(non_neg_integer() | nil) :: atom()
  def status_name(code), do: Map.get(@status_names, code, :unknown)

  @doc "The numeric gRPC status code of a snake_case status name."
  @spec status_code(atom()) :: non_neg_integer()
  def status_code(name), do: Map.fetch!(@codes, name)

  @doc "Builds a `GRPC.RPCError` from a status name and message."
  @spec rpc_error(atom(), String.t()) :: GRPC.RPCError.t()
  def rpc_error(status, message) do
    GRPC.RPCError.exception(status: status_code(status), message: message)
  end

  @doc """
  Turns anything returned or raised by the transport into a `GRPC.RPCError`.
  """
  @spec normalize(term()) :: GRPC.RPCError.t()
  def normalize(%GRPC.RPCError{status: 2, message: message} = error) when is_binary(message) do
    if connection_failure?(message), do: %{error | status: status_code(:unavailable)}, else: error
  end

  def normalize(%GRPC.RPCError{} = error), do: error
  def normalize(:no_connection), do: rpc_error(:unavailable, "no connection available")
  def normalize(:timeout), do: rpc_error(:deadline_exceeded, "deadline exceeded")
  def normalize(:not_started), do: rpc_error(:unavailable, "client connection is not running")

  def normalize({:exit, reason}),
    do: rpc_error(:unavailable, "connection process exited: #{inspect(reason)}")

  def normalize(message) when is_binary(message) do
    if connection_failure?(message),
      do: rpc_error(:unavailable, message),
      else: rpc_error(:unknown, message)
  end

  def normalize(%{__exception__: true} = exception),
    do: rpc_error(:internal, Exception.message(exception))

  def normalize(other), do: rpc_error(:unknown, inspect(other))

  # The Mint adapter reports a dropped / not (yet) re-established connection as an UNKNOWN error
  # whose message embeds one of these strings. They are transport failures (UNAVAILABLE).
  defp connection_failure?(message) do
    String.contains?(message, [
      "the connection is closed",
      "Error while opening connection",
      "connection process",
      ":closed",
      "econnrefused"
    ])
  end

  @doc """
  Maps a `GRPC.RPCError` into the exception returned to callers.

  `opts` are passed through to `AshGrpc.Error.from_rpc_error/2` (`:client`, `:service`, `:rpc`).
  """
  @spec from_rpc_error(GRPC.RPCError.t(), keyword()) :: Exception.t()
  def from_rpc_error(%GRPC.RPCError{} = error, opts \\ []) do
    AshGrpc.Error.from_rpc_error(error, opts)
  end
end
