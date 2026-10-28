defmodule AshGrpc.Client.Codec do
  @moduledoc """
  A `GRPC.Codec` that defers protobuf decoding of responses to the calling process.

  grpc's Mint adapter decodes responses inside a helper process linked to the caller, where
  neither a size check nor a decode failure can be reported as an error. When a client sets
  `:max_receive_message_size`, calls use this codec: `decode/2` only wraps the raw bytes in an
  `AshGrpc.Client.Codec.Raw` struct, and the client checks the size and decodes in the caller
  (`AshGrpc.Client.Codec.finalize/2`), turning failures into `RESOURCE_EXHAUSTED` / `INTERNAL`
  errors. Client interceptors see the `Raw` struct as the response in that mode.
  """

  @behaviour GRPC.Codec

  defmodule Raw do
    @moduledoc "An undecoded response message (see `AshGrpc.Client.Codec`)."
    @type t :: %__MODULE__{binary: binary(), module: module()}
    defstruct [:binary, :module]
  end

  @impl GRPC.Codec
  def name, do: "proto"

  @impl GRPC.Codec
  def encode(struct, _opts \\ []), do: Protobuf.encode_to_iodata(struct)

  @impl GRPC.Codec
  def decode(binary, module), do: %Raw{binary: binary, module: module}

  @doc """
  Decodes a `Raw` message, enforcing `max_size` bytes (`nil` for no limit). Already decoded
  values are returned unchanged.
  """
  @spec finalize(term(), pos_integer() | nil) ::
          {:ok, term()} | {:error, AshGrpc.Types.rpc_error()}
  def finalize(%Raw{binary: binary}, max) when is_integer(max) and byte_size(binary) > max do
    {:error,
     AshGrpc.Client.Errors.rpc_error(
       :resource_exhausted,
       "received message larger than max (#{byte_size(binary)} vs. #{max})"
     )}
  end

  def finalize(%Raw{binary: binary, module: module}, _max) do
    {:ok, Protobuf.decode(binary, module)}
  rescue
    error ->
      {:error,
       AshGrpc.Client.Errors.rpc_error(
         :internal,
         "failed to decode #{inspect(module)}: #{Exception.message(error)}"
       )}
  end

  def finalize(value, _max), do: {:ok, value}
end
