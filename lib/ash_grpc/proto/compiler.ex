defmodule AshGrpc.Proto.Compiler do
  @moduledoc """
  Turns an `AshGrpc.Proto.IR.Schema` into Elixir modules compatible with the
  `protobuf` and `grpc` libraries (the same shape `protoc-gen-elixir` emits,
  including descriptors so `grpc_reflection` works).

  Every `IR.Message`/`IR.Enum`/`IR.Service` must have `:module` set; a service
  also yields a `<Service>.Stub` client module.

  > #### Stub {: .warning}
  >
  > Owned by the "proto toolkit" work package (see DESIGN.md). The contract is stable.
  """

  alias AshGrpc.Proto.IR

  @doc "Quoted module definitions, one per message/enum/service/stub."
  @spec quoted(IR.Schema.t(), Keyword.t()) :: [{module(), Macro.t()}]
  def quoted(%IR.Schema{}, _opts \\ []),
    do: raise("AshGrpc.Proto.Compiler.quoted/2 is not implemented yet")

  @doc "Compiles the modules into the running VM (used at compile time by endpoints and `use AshGrpc.Protos`)."
  @spec compile(IR.Schema.t(), Keyword.t()) :: [module()]
  def compile(%IR.Schema{}, _opts \\ []),
    do: raise("AshGrpc.Proto.Compiler.compile/2 is not implemented yet")

  @doc "Formatted Elixir source files, as `{relative_path, source}` (used by `mix ash_grpc.import`)."
  @spec to_source(IR.Schema.t(), Keyword.t()) :: [{Path.t(), String.t()}]
  def to_source(%IR.Schema{}, _opts \\ []),
    do: raise("AshGrpc.Proto.Compiler.to_source/2 is not implemented yet")
end
