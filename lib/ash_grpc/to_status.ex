defprotocol AshGrpc.ToStatus do
  @moduledoc """
  Converts an error into what it contributes to a gRPC status.

  Implemented for the core Ash errors (see `AshGrpc.Error` for the table).
  Implement it for your own exceptions to control the status code, the message
  and the details clients receive:

      defimpl AshGrpc.ToStatus, for: MyApp.Errors.QuotaExceeded do
        def to_status(error) do
          %AshGrpc.Error.Info{
            code: :resource_exhausted,
            message: "quota exceeded",
            public?: true,
            reason: "QUOTA_EXCEEDED",
            metadata: %{"limit" => to_string(error.limit)}
          }
        end
      end

  Errors without an implementation fall back to their Splode class
  (`:invalid` → `INVALID_ARGUMENT`, `:forbidden` → `PERMISSION_DENIED`,
  anything else → `INTERNAL`) with a non-public message.
  """

  @fallback_to_any true

  @doc "Returns the status information of a single (non-class) error."
  @spec to_status(t()) :: AshGrpc.Error.Info.t()
  def to_status(error)
end

defimpl AshGrpc.ToStatus, for: Any do
  alias AshGrpc.Error.{Helpers, Info}

  def to_status(%{class: :invalid} = error) do
    %Info{code: :invalid_argument, message: Helpers.message(error), reason: Helpers.reason(error)}
  end

  def to_status(%{class: :forbidden} = error) do
    %Info{
      code: :permission_denied,
      message: Helpers.message(error),
      reason: "FORBIDDEN"
    }
  end

  def to_status(error) do
    %Info{code: :internal, message: Helpers.message(error), reason: "INTERNAL"}
  end
end
