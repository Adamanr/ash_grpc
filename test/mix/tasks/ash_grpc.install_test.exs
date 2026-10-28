defmodule Mix.Tasks.AshGrpc.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp assert_content(igniter, path, expected) do
    content = igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
    assert content =~ expected
    igniter
  end

  test "creates the endpoint, supervises the server, configures prod and the formatter" do
    test_project()
    |> Igniter.compose_task("ash_grpc.install", [])
    |> assert_creates("lib/test/grpc_endpoint.ex", """
    defmodule Test.GrpcEndpoint do
      @moduledoc "gRPC endpoint: serves the AshGrpc services of the listed domains."

      use AshGrpc.Endpoint,
        otp_app: :test,
        # domains using `AshGrpc.Domain`, e.g. [MyApp.Accounts]
        domains: [],
        reflection: true,
        health: true
    end
    """)
    |> assert_content(
      "lib/test/application.ex",
      "{AshGrpc.Server, [endpoint: Test.GrpcEndpoint, port: 50051]}"
    )
    |> assert_content("config/prod.exs", "config :ash_grpc, require_lock?: true")
    |> assert_content(".formatter.exs", "import_deps: [:ash_grpc]")
    |> assert_has_notice(&(&1 =~ "mix ash_grpc.codegen"))
  end

  test "honours --endpoint and --port and is idempotent" do
    igniter =
      test_project()
      |> Igniter.compose_task("ash_grpc.install", [
        "--endpoint",
        "Test.Api.Grpc",
        "--port",
        "6000"
      ])
      |> assert_creates("lib/test/api/grpc.ex")
      |> assert_content(
        "lib/test/application.ex",
        "{AshGrpc.Server, [endpoint: Test.Api.Grpc, port: 6000]}"
      )

    igniter
    |> apply_igniter!()
    |> Igniter.compose_task("ash_grpc.install", ["--endpoint", "Test.Api.Grpc", "--port", "6000"])
    |> assert_unchanged()
  end
end
