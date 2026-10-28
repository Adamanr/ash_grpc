defmodule Mix.Tasks.AshGrpc.Install.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc, do: "Installs AshGrpc into a project"

  @spec example() :: String.t()
  def example, do: "mix igniter.install ash_grpc"

  @spec long_doc() :: String.t()
  def long_doc do
    """
    #{short_doc()}

    Run it with `#{example()}` (or `mix ash_grpc.install` once the dependency is added). It:

      * imports the `ash_grpc` formatter rules (`import_deps`)
      * creates an endpoint module (`<App>.GrpcEndpoint`) serving every domain that uses
        `AshGrpc.Domain`, with health checks and reflection enabled
      * adds `{AshGrpc.Server, endpoint: <App>.GrpcEndpoint, port: 50051}` to the application
        supervision tree
      * sets `config :ash_grpc, require_lock?: true` in `config/prod.exs`, so production builds
        fail when the field-number lock is stale (run `mix ash_grpc.codegen` to update it)

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

      * `--endpoint` – endpoint module (default `<App>.GrpcEndpoint`)
      * `--port` – port of the gRPC server (default `50051`)
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshGrpc.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @default_port 50_051

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: __MODULE__.Docs.example(),
        schema: [endpoint: :string, port: :integer],
        defaults: [port: @default_port]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      otp_app = Igniter.Project.Application.app_name(igniter)

      endpoint =
        case options[:endpoint] do
          nil -> Igniter.Project.Module.module_name(igniter, "GrpcEndpoint")
          name -> Igniter.Project.Module.parse(name)
        end

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_grpc)
      |> create_endpoint(endpoint, otp_app)
      |> Igniter.Project.Application.add_new_child(
        {AshGrpc.Server, [endpoint: endpoint, port: options[:port] || @default_port]}
      )
      |> Igniter.Project.Config.configure("prod.exs", :ash_grpc, [:require_lock?], true)
      |> Igniter.add_notice("""
      AshGrpc:

        * add `extensions: [AshGrpc.Domain]` to your domains and `extensions: [AshGrpc.Resource]`
          to your resources, then describe the API in `grpc do ... end`
        * list the domains in #{inspect(endpoint)}
        * run `mix ash_grpc.codegen` (or `mix ash.codegen`) to write priv/protos and the lock
      """)
    end

    defp create_endpoint(igniter, endpoint, otp_app) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, endpoint)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, endpoint, """
        @moduledoc "gRPC endpoint: serves the AshGrpc services of the listed domains."

        use AshGrpc.Endpoint,
          otp_app: #{inspect(otp_app)},
          # domains using `AshGrpc.Domain`, e.g. [MyApp.Accounts]
          domains: [],
          reflection: true,
          health: true
        """)
      end
    end
  end
else
  defmodule Mix.Tasks.AshGrpc.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_grpc.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
