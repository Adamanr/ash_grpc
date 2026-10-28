defmodule AshGrpc.Test.Types.Role do
  @moduledoc false
  use Ash.Type.Enum,
    values: [admin: "Full access", member: "Regular member", guest: "Read only"]
end

defmodule AshGrpc.Test.Types.Status do
  @moduledoc false
  use Ash.Type.NewType, subtype_of: :atom, constraints: [one_of: [:active, :archived]]
end

defmodule AshGrpc.Test.Types.Address do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        street: [type: :string, allow_nil?: false],
        city: [type: :string],
        zip: [type: :integer],
        tags: [type: {:array, :string}],
        geo: [
          type: :map,
          constraints: [
            fields: [
              lat: [type: :float, allow_nil?: false],
              lng: [type: :float, allow_nil?: false]
            ]
          ]
        ]
      ]
    ]
end

defmodule AshGrpc.Test.Types.Money do
  @moduledoc false
  # A custom type with its own protobuf representation (google.type.Money).
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        currency: [type: :string, allow_nil?: false],
        amount: [type: :decimal, allow_nil?: false]
      ]
    ]

  @behaviour AshGrpc.Type

  @impl AshGrpc.Type
  def proto_type(_constraints) do
    {:ok,
     %AshGrpc.Type.Mapping.Result{
       type: {:message, "google.type.Money"},
       imports: ["google/type/money.proto"]
     }}
  end

  @impl AshGrpc.Type
  def encode_proto(%{currency: currency, amount: amount}, _constraints) do
    units = amount |> Decimal.round(0, :down) |> Decimal.to_integer()
    nanos = amount |> Decimal.sub(units) |> Decimal.mult(1_000_000_000) |> Decimal.to_integer()
    {:ok, %Google.Type.Money{currency_code: currency, units: units, nanos: nanos}}
  end

  @impl AshGrpc.Type
  def decode_proto(%Google.Type.Money{} = money, _constraints) do
    amount = Decimal.add(Decimal.new(money.units), Decimal.div(money.nanos, 1_000_000_000))
    {:ok, %{currency: money.currency_code, amount: Decimal.normalize(amount)}}
  end
end

defmodule AshGrpc.Test.Types.Slug do
  @moduledoc false
  # A custom type that only changes the mapping; the default codec is used.
  use Ash.Type.NewType, subtype_of: :string
  @behaviour AshGrpc.Type

  @impl AshGrpc.Type
  def proto_type(_constraints),
    do: {:ok, %AshGrpc.Type.Mapping.Result{type: {:message, "google.protobuf.StringValue"}}}
end

defmodule AshGrpc.Test.Types.Profile do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :bio, :string, public?: true
    attribute :role, AshGrpc.Test.Types.Role, public?: true
    attribute :birthday, :date, public?: true
  end
end
