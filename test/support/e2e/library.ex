defmodule AshGrpc.Test.E2E.Library do
  @moduledoc false
  # The API served in the end-to-end tests (test/e2e). Its field numbers are locked in
  # test/support/e2e/library.lock.json; regenerate it with
  #   MIX_ENV=test mix ash_grpc.codegen --domains AshGrpc.Test.E2E.Library \
  #     --lock test/support/e2e/library.lock.json --out tmp/e2e/protos --snapshots tmp/e2e/snapshots
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.e2e.library.v1"
    module_prefix AshGrpc.Test.E2E.Proto.V1

    service "LibraryService"
  end

  resources do
    resource AshGrpc.Test.E2E.Book
    resource AshGrpc.Test.E2E.Note
  end
end

defmodule AshGrpc.Test.E2E.BookStatus do
  @moduledoc false
  use Ash.Type.Enum, values: [:draft, :published]
end

defmodule AshGrpc.Test.E2E.Book do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.E2E.Library,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true, constraints: [min_length: 1]
    attribute :author, :string, public?: true
    attribute :pages, :integer, public?: true, constraints: [min: 1]

    attribute :status, AshGrpc.Test.E2E.BookStatus, default: :draft, public?: true

    attribute :tags, {:array, :string}, public?: true, default: []
    create_timestamp :inserted_at, public?: true
  end

  calculations do
    calculate :headline, :string, expr(title <> " by " <> (author || "unknown")), public?: true
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:title, :author, :pages, :status, :tags],
      update: [:title, :author, :pages, :status, :tags]
    ]

    read :list do
      argument :author, :string
      argument :status, AshGrpc.Test.E2E.BookStatus

      filter expr(
               (is_nil(^arg(:author)) or author == ^arg(:author)) and
                 (is_nil(^arg(:status)) or status == ^arg(:status))
             )

      pagination keyset?: true, required?: false, countable: true, max_page_size: 100
    end
  end

  grpc do
    fields [:id, :title, :author, :pages, :status, :tags, :inserted_at, :headline]

    rpc :get_book, :read, kind: :get
    rpc :list_books, :list
    rpc :watch_books, :read, kind: :server_stream
    rpc :create_book, :create
    rpc :update_book, :update, update_mask?: true
    rpc :delete_book, :destroy
  end
end

defmodule AshGrpc.Test.E2E.Note do
  @moduledoc false
  # Private notes: every rpc needs an actor (sent as `authorization: Bearer <id>` metadata).
  use Ash.Resource,
    domain: AshGrpc.Test.E2E.Library,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :owner_id, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:body]
      change set_attribute(:owner_id, actor(:id))
    end

    update :update do
      primary? true
      accept [:body]
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end

  grpc do
    rpc :get_note, :read, kind: :get
    rpc :list_notes, :read
    rpc :create_note, :create
    rpc :update_note, :update, update_mask?: true
    rpc :delete_note, :destroy
  end
end

defmodule AshGrpc.Test.E2E.Auth do
  @moduledoc false
  @behaviour AshGrpc.Actor

  @impl true
  def get_actor(metadata, _stream) do
    case metadata["authorization"] do
      nil -> {:ok, nil}
      "Bearer " <> id when id != "" -> {:ok, %{id: id}}
      _ -> {:error, :unauthenticated}
    end
  end
end

defmodule AshGrpc.Test.E2E.Endpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    otp_app: :ash_grpc,
    domains: [AshGrpc.Test.E2E.Library],
    lock_path: "test/support/e2e/library.lock.json",
    require_lock?: true,
    interceptors: [{AshGrpc.Interceptors.Actor, from: AshGrpc.Test.E2E.Auth}],
    reflection: true,
    health: true
end
