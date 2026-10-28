defmodule AshGrpc.Error.Unauthenticated do
  @moduledoc """
  The request carries no (valid) credentials. Mapped to `UNAUTHENTICATED`.

  Raised/returned by actor interceptors when authentication is required.
  """

  use Splode.Error, fields: [message: "unauthenticated"], class: :forbidden

  @impl true
  def message(%{message: message}), do: message
end
