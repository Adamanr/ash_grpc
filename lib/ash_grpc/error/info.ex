defmodule AshGrpc.Error.Info do
  @moduledoc """
  What a single error contributes to a gRPC status (returned by `AshGrpc.ToStatus`).

    * `code` – gRPC status code atom (`:invalid_argument`, `:not_found`, …)
    * `message` – human readable message
    * `public?` – whether `message` may be sent to clients. Non-public messages
      are replaced by a generic one unless `show_raised_errors?: true`.
    * `reason` – `google.rpc.ErrorInfo.reason` (`UPPER_SNAKE_CASE`)
    * `metadata` – `google.rpc.ErrorInfo.metadata` (string keys and values;
      only put data here that is safe to show)
    * `field_violations` – entries of `google.rpc.BadRequest`, `path` is a list of
      Ash field names / list indices (translated to proto field paths by
      `AshGrpc.Error`)
    * `resource_info` – `google.rpc.ResourceInfo` fields
  """

  defstruct code: :internal,
            message: nil,
            public?: false,
            reason: nil,
            metadata: %{},
            field_violations: [],
            resource_info: nil

  @type code ::
          :cancelled
          | :unknown
          | :invalid_argument
          | :deadline_exceeded
          | :not_found
          | :already_exists
          | :permission_denied
          | :resource_exhausted
          | :failed_precondition
          | :aborted
          | :out_of_range
          | :unimplemented
          | :internal
          | :unavailable
          | :data_loss
          | :unauthenticated

  @type field_violation :: %{
          required(:path) => [atom() | String.t() | non_neg_integer()],
          required(:description) => String.t(),
          optional(:reason) => String.t() | nil
        }

  @type resource_info :: %{
          optional(:resource_type) => String.t(),
          optional(:resource_name) => String.t(),
          optional(:owner) => String.t(),
          optional(:description) => String.t()
        }

  @type t :: %__MODULE__{
          code: code(),
          message: String.t() | nil,
          public?: boolean(),
          reason: String.t() | nil,
          metadata: %{optional(String.t()) => String.t()},
          field_violations: [field_violation()],
          resource_info: resource_info() | nil
        }

  @codes %{
    cancelled: 1,
    unknown: 2,
    invalid_argument: 3,
    deadline_exceeded: 4,
    not_found: 5,
    already_exists: 6,
    permission_denied: 7,
    resource_exhausted: 8,
    failed_precondition: 9,
    aborted: 10,
    out_of_range: 11,
    unimplemented: 12,
    internal: 13,
    unavailable: 14,
    data_loss: 15,
    unauthenticated: 16
  }

  @doc "gRPC status number of a code atom."
  @spec status(code()) :: non_neg_integer()
  def status(code), do: Map.fetch!(@codes, code)

  @doc "Code atom of a gRPC status number (`:unknown` for unknown numbers)."
  @spec code(non_neg_integer()) :: code() | :ok
  def code(0), do: :ok

  def code(status) do
    Enum.find_value(@codes, :unknown, fn {code, number} -> if number == status, do: code end)
  end

  @doc "All status code atoms."
  @spec codes() :: [code()]
  def codes, do: Map.keys(@codes)
end
