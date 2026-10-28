defmodule AshGrpcExample.Application do
  @moduledoc """
  Starts the services configured in `config :ash_grpc_example, :services`:

    * `:library` – the AshGrpc server (`Library.GrpcEndpoint`) on `:library_port`,
    * `:frontdesk` – the client of the library service used by the `Frontdesk` domain.
  """
  use Application

  @impl true
  def start(_type, _args) do
    services = Application.fetch_env!(:ash_grpc_example, :services)
    children = Enum.flat_map(services, &children/1)
    Supervisor.start_link(children, strategy: :one_for_one, name: AshGrpcExample.Supervisor)
  end

  @doc "The child specs of one service."
  @spec children(:library | :frontdesk, keyword()) :: [Supervisor.child_spec() | {module, term}]
  def children(service, opts \\ [])

  def children(:library, opts) do
    port =
      Keyword.get_lazy(opts, :port, fn ->
        Application.fetch_env!(:ash_grpc_example, :library_port)
      end)

    [{AshGrpc.Server, endpoint: Library.GrpcEndpoint, port: port}]
  end

  def children(:frontdesk, opts), do: [{Frontdesk.LibraryClient, opts}]
end
