defmodule Frontdesk.Proto do
  @moduledoc """
  The protobuf and gRPC modules of the library service, compiled from its `.proto` file when
  this module compiles (requires `protoc`): `Frontdesk.Proto.Book`,
  `Frontdesk.Proto.LibraryService.Service`, ...
  """
  use AshGrpc.Protos,
    files: ["priv/protos/library/v1/library.proto"],
    include: ["priv/protos"],
    module_prefix: Frontdesk.Proto
end
