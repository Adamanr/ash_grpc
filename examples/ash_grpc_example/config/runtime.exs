import Config

# SERVICES=library mix run --no-halt     -> only the gRPC server
# SERVICES=frontdesk mix run --no-halt   -> only the consumer (LIBRARY_ADDRESS=host:port)
if services = System.get_env("SERVICES") do
  config :ash_grpc_example,
    services: services |> String.split(",", trim: true) |> Enum.map(&String.to_existing_atom/1)
end

if port = System.get_env("LIBRARY_PORT") do
  config :ash_grpc_example, library_port: String.to_integer(port)
end

if address = System.get_env("LIBRARY_ADDRESS") do
  config :ash_grpc_example, Frontdesk.LibraryClient, address: address
end
