defmodule AshGrpcExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_grpc_example,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {AshGrpcExample.Application, []}]
  end

  defp deps do
    [
      {:ash_grpc, path: "../.."},
      # server reflection, so grpcurl works without .proto files
      {:grpc_reflection, "~> 0.5"},
      # SAT solver for the library policies
      {:simple_sat, "~> 0.1"}
    ]
  end
end
