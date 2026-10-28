defmodule AshGrpc.Test.Accounts do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.test.accounts.v1"
    file "ashgrpc/test/accounts/v1/accounts.proto"
    module_prefix AshGrpc.Test.Proto.Accounts.V1
    doc "Accounts API"
    imports ["google/api/annotations.proto"]

    option :go_package, "example.com/gen/accounts/v1;accountsv1"
    option :java_multiple_files, true

    service "AccountsService", doc: "Users", options: [deprecated: false]
    service "AdminService", rpcs: [:ban_user], doc: "Back office"
    service "PostsService", resources: [AshGrpc.Test.Post]
  end

  resources do
    resource AshGrpc.Test.User
    resource AshGrpc.Test.Post
  end
end

defmodule AshGrpc.Test.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Accounts,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  resource do
    description "A user account"
  end

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :email, :string, allow_nil?: false, public?: true, description: "Login"
    attribute :name, :string, public?: true
    attribute :age, :integer, public?: true

    attribute :role, :atom,
      constraints: [one_of: [:admin, :member]],
      default: :member,
      public?: true

    attribute :score, :float, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :tags, {:array, :string}, public?: true
    attribute :profile, AshGrpc.Test.Profile, public?: true
    attribute :addresses, {:array, AshGrpc.Test.Address}, public?: true
    attribute :settings, :map, public?: true
    attribute :payload, :term, public?: true
    attribute :secret, :string
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    has_many :posts, AshGrpc.Test.Post, public?: true
  end

  calculations do
    calculate :display_name, :string, expr(name <> " <" <> email <> ">"), public?: true
    calculate :adult?, :boolean, expr(age >= 18), public?: true
  end

  aggregates do
    count :posts_count, :posts, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :by_email do
      get? true
      argument :email, :string, allow_nil?: false
      filter expr(email == ^arg(:email))
    end

    read :search do
      argument :query, :string
      argument :internal, :string, public?: false
      pagination keyset?: true, required?: false
    end

    create :register do
      accept [:email, :name, :age, :profile]
      argument :password, :string, allow_nil?: false, sensitive?: true
    end

    update :rename do
      accept [:name]
    end

    destroy :archive do
      argument :reason, :string
    end

    action :ping, :string do
      argument :message, :string
      run fn input, _ -> {:ok, input.arguments.message} end
    end

    action :ban_user do
      argument :id, :uuid, allow_nil?: false
      run fn _, _ -> :ok end
    end

    action :export, AshGrpc.Test.Profile do
      run fn _, _ -> {:ok, nil} end
    end

    action :emails, {:array, :string} do
      run fn _, _ -> {:ok, []} end
    end
  end

  grpc do
    message "User"
    doc "A user (proto)"
    options [{"(my.ext).table", "users"}]

    fields [
      :id,
      :email,
      :name,
      :age,
      :role,
      :score,
      :active,
      :tags,
      :profile,
      :addresses,
      :settings,
      :payload,
      :secret,
      :inserted_at,
      :display_name,
      :adult?,
      :posts_count,
      :posts
    ]

    field :id, number: 1
    field :email, number: 2, doc: "Primary email", json_name: "emailAddress"
    field :name, deprecated?: true, options: [{"(my.ext).sensitive", true}]
    field :payload, representation: :bytes
    field :adult?, proto_name: "is_adult"
    field :inserted_at, number: 20

    reserved numbers: [5, 10..12, {100, :max}], names: ["legacy_name"]

    rpc :get_user, :read, get_by: [:id], read_mask?: true, load: [:posts]
    rpc :get_user_by_email, :by_email
    rpc :list_users, :search, filter?: true, read_mask?: true
    rpc :watch_users, :read, kind: :server_stream
    rpc :create_user, :create
    rpc :register, :register, request_message: "SignUpRequest", doc: "Sign up"
    rpc :create_user_wrapped, :create, input: :wrapped
    rpc :import_users, :create, kind: :client_stream
    rpc :update_user, :update, update_mask?: true, idempotency_level: :idempotent
    rpc :rename_user, :rename, input: :wrapped
    rpc :delete_user, :destroy
    rpc :archive_user, :archive, return_destroyed?: true, deprecated?: true
    rpc :ping, :ping, idempotency_level: :no_side_effects, options: [{"(my.ext).public", true}]
    rpc :ban_user, :ban_user
    rpc :export_profile, :export
    rpc :list_emails, :emails, response_message: "EmailList", service: "ExportService"
    rpc :sync, :read, kind: :bidi_stream, handler: AshGrpc.Test.SyncHandler
  end
end

defmodule AshGrpc.Test.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Accounts,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  ets do
    private? true
  end

  attributes do
    integer_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :published_at, :utc_datetime, public?: true
  end

  relationships do
    belongs_to :user, AshGrpc.Test.User, public?: true, attribute_type: :uuid
  end

  actions do
    defaults [:read, create: [:title, :user_id]]
  end

  grpc do
    rpc :list_posts, :read
    rpc :create_post, :create, response_message: AshGrpc.Test.ExternalPost
  end
end

defmodule AshGrpc.Test.SyncHandler do
  @moduledoc false
end

defmodule AshGrpc.Test.ExternalPost do
  @moduledoc false
  use Protobuf, full_name: "external.v1.Post", syntax: :proto3

  field :title, 1, type: :string
end
