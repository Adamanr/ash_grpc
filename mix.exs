defmodule AshGrpc.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ash-project/ash_grpc"

  def project do
    [
      app: :ash_grpc,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      package: package(),
      description:
        "gRPC for the Ash Framework: expose resources as gRPC services, generate .proto files, and consume external gRPC services.",
      source_url: @source_url,
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.37"},
      {:spark, "~> 2.7"},
      {:protobuf, "~> 0.17"},
      {:grpc, "~> 1.0"},
      {:grpc_server, "~> 1.0"},
      {:googleapis, "~> 0.1"},
      {:grpc_reflection, "~> 0.5", optional: true},
      {:igniter, "~> 0.8", optional: true},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      # dev / test
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:simple_sat, "~> 0.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      "spark.cheat_sheets":
        "spark.cheat_sheets --extensions AshGrpc.Resource,AshGrpc.Domain,AshGrpc.DataLayer",
      "spark.formatter":
        "spark.formatter --extensions AshGrpc.Resource,AshGrpc.Domain,AshGrpc.DataLayer",
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "DESIGN.md",
        "documentation/dsls/DSL-AshGrpc.Resource.md",
        "documentation/dsls/DSL-AshGrpc.Domain.md"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
