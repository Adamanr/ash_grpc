import Config

config :ash, default_string_length_count: :codepoints

config :ash_grpc_example, ash_domains: [Library, Frontdesk]

# Which services this node runs (see config/runtime.exs for the SERVICES variable).
config :ash_grpc_example, services: [:library, :frontdesk], library_port: 50051

config :ash_grpc_example, Frontdesk.LibraryClient,
  address: "localhost:50051",
  deadline: 5_000,
  retry: [max_attempts: 3]

if config_env() == :test do
  # tests start the services themselves, on a free port
  config :ash_grpc_example, services: []
  config :logger, level: :warning
end

if config_env() == :prod do
  config :ash_grpc, require_lock?: true
end
