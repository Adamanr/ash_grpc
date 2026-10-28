defmodule Frontdesk.LibraryClient do
  @moduledoc """
  The client of the library service. The actor of an Ash call (a librarian) is sent as a
  bearer token, so the library's policies see who is acting.
  """
  require Frontdesk.Proto

  use AshGrpc.Client,
    otp_app: :ash_grpc_example,
    services: [Frontdesk.Proto.LibraryService.Service]

  @impl AshGrpc.Client
  def init(config), do: {:ok, Keyword.put(config, :metadata, &__MODULE__.metadata/1)}

  @doc false
  def metadata(%{opts: opts}) do
    case opts[:actor] do
      %{name: name} -> %{"authorization" => "Bearer #{name}"}
      _ -> %{}
    end
  end
end
