defmodule Library do
  @moduledoc """
  The serving side of the example: a small library catalogue exposed over gRPC.

  Reads are public; creating, updating and deleting books needs an actor (a librarian, sent as
  `authorization: Bearer <name>` metadata, see `Library.Auth`).
  """
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    package "library.v1"
    module_prefix Library.Proto.V1
    service "LibraryService"
  end

  resources do
    resource Library.Book
  end
end
