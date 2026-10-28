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
      docs: &docs/0,
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
      # transport of AshGrpc clients (an optional dependency of grpc, whose Mint adapter is only
      # compiled when mint is present)
      {:mint, "~> 1.9"},
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
      extra_section: "GUIDES",
      # references to modules hidden in their own docs (protobuf's descriptor modules, the
      # compiled google.rpc.Status) and to the internal client runtime
      skip_code_autolink_to: [
        "AshGrpc.Server.Proto.Google.Rpc.Status",
        "Google.Protobuf.DescriptorProto",
        "Google.Protobuf.FileDescriptorProto",
        "Google.Protobuf.FileDescriptorSet"
      ],
      skip_undefined_reference_warnings_on: [
        "AshGrpc.Client.Pool",
        "AshGrpc.Proto.Compiler",
        "AshGrpc.Proto.Import",
        "AshGrpc.Proto.Import.Comments",
        "AshGrpc.Proto.Import.Mapper",
        "AshGrpc.Proto.Import.Registry"
      ],
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/getting-started.md",
        "documentation/topics/consuming-services.md",
        "documentation/topics/protocol-and-compatibility.md",
        "documentation/topics/auth-tenancy-interceptors.md",
        "documentation/topics/testing.md",
        "documentation/topics/escape-hatches.md",
        {"documentation/dsls/DSL-AshGrpc.Resource.md",
         search_data: Spark.Docs.search_data_for(AshGrpc.Resource)},
        {"documentation/dsls/DSL-AshGrpc.Domain.md",
         search_data: Spark.Docs.search_data_for(AshGrpc.Domain)},
        {"documentation/dsls/DSL-AshGrpc.DataLayer.md",
         search_data: Spark.Docs.search_data_for(AshGrpc.DataLayer)},
        "DESIGN.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        "Start Here": ["README.md", "documentation/topics/getting-started.md"],
        Guides: ~r"documentation/topics",
        Reference: [~r"documentation/dsls", "DESIGN.md", "CHANGELOG.md"]
      ],
      groups_for_modules: [
        Serving: [
          AshGrpc.Resource,
          AshGrpc.Resource.Info,
          AshGrpc.Domain,
          AshGrpc.Domain.Info,
          AshGrpc.Endpoint,
          AshGrpc.Server,
          ~r/^AshGrpc\.Server\./,
          AshGrpc.Actor,
          ~r/^AshGrpc\.Interceptors\./
        ],
        Consuming: [
          AshGrpc.Client,
          ~r/^AshGrpc\.Client\./,
          AshGrpc.Rpc,
          AshGrpc.DataLayer,
          ~r/^AshGrpc\.DataLayer\./,
          AshGrpc.Protos
        ],
        "Types & errors": [
          AshGrpc.Type,
          ~r/^AshGrpc\.Type\./,
          AshGrpc.Codec,
          ~r/^AshGrpc\.Codec\./,
          AshGrpc.Error,
          ~r/^AshGrpc\.Error\./,
          AshGrpc.ToStatus,
          AshGrpc.Types
        ],
        "Proto toolkit": [
          AshGrpc.Schema,
          ~r/^AshGrpc\.Schema\./,
          ~r/^AshGrpc\.Proto\./,
          AshGrpc.Codegen,
          ~r/^AshGrpc\.Codegen\./
        ],
        Internals: [
          ~r/^AshGrpc\.Resource\./,
          ~r/^AshGrpc\.Domain\./
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files:
        ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE* usage-rules.md documentation),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end
end
