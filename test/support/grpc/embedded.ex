defmodule AshGrpc.Test.Address do
  @moduledoc false
  # Embedded resource without the AshGrpc.Resource extension: public attributes become fields.
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :street, :string, public?: true
    attribute :city, :string, allow_nil?: false, public?: true
    attribute :internal_code, :string
  end
end

defmodule AshGrpc.Test.Profile do
  @moduledoc false
  # Embedded resource tuned with the AshGrpc.Resource extension.
  use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]

  attributes do
    attribute :bio, :string, public?: true, description: "Free text"
    attribute :website, :string, public?: true
    attribute :home, AshGrpc.Test.Address, public?: true
    attribute :private_note, :string
  end

  grpc do
    message "UserProfile"
    fields [:bio, :home, :private_note]
    field :bio, number: 1
    field :private_note, number: 7, proto_name: "note"
  end
end
