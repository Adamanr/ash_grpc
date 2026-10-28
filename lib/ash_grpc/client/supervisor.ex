defmodule AshGrpc.Client.Supervisor do
  @moduledoc """
  Supervisor of one client: a keeper process publishing the client's runtime state, followed
  by its pooled connections (or, for `connect: :lazy`, a `DynamicSupervisor` for them).

  It is registered under the client name. Shutting it down closes the connections first and
  unpublishes the client last.
  """

  use Supervisor

  alias AshGrpc.Client.{Config, Pool, Runtime}

  @doc "Starts the supervisor for a validated configuration."
  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(%Config{name: name} = config) do
    Supervisor.start_link(__MODULE__, config, name: name)
  end

  @impl true
  def init(%Config{} = config) do
    runtime = Runtime.new(config)

    connections =
      if config.sandbox, do: [], else: Pool.child_specs(runtime)

    children = [{Runtime.Keeper, runtime} | connections]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
