defmodule AshGrpc.Type do
  @moduledoc """
  Behaviour for Ash types that want to control their protobuf representation.

  Implement it in your `Ash.Type` (or `Ash.Type.NewType`) module:

      defmodule MyApp.Types.Money do
        use Ash.Type.NewType, subtype_of: :map, constraints: [...]
        @behaviour AshGrpc.Type

        @impl AshGrpc.Type
        def proto_type(_constraints) do
          {:ok, %AshGrpc.Type.Mapping.Result{type: {:message, "google.type.Money"}, imports: ["google/type/money.proto"]}}
        end

        @impl AshGrpc.Type
        def encode_proto(%{amount: a, currency: c}, _constraints), do: {:ok, %Google.Type.Money{...}}

        @impl AshGrpc.Type
        def decode_proto(%Google.Type.Money{} = m, _constraints), do: {:ok, %{...}}
      end

  `encode_proto/2` turns a cast Ash value into the value stored in the protobuf
  struct field; `decode_proto/2` does the opposite (the result is then cast by Ash).
  Both are optional: the default codec (`AshGrpc.Codec`) is used when absent.
  """

  @callback proto_type(constraints :: Keyword.t()) ::
              {:ok, AshGrpc.Type.Mapping.Result.t()} | {:error, term()}
  @callback encode_proto(value :: term(), constraints :: Keyword.t()) ::
              {:ok, term()} | {:error, term()}
  @callback decode_proto(value :: term(), constraints :: Keyword.t()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks encode_proto: 2, decode_proto: 2
end
