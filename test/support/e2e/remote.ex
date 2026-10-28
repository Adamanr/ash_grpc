defmodule AshGrpc.Test.E2E.LibraryClient do
  @moduledoc false
  # The consuming side of the end-to-end tests: a client of the served LibraryService. The actor
  # of an Ash call (a call option set by AshGrpc.DataLayer) travels as a bearer token.
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [AshGrpc.Test.E2E.Proto.V1.LibraryService.Service]

  @impl AshGrpc.Client
  def init(config) do
    {:ok, Keyword.put(config, :metadata, &__MODULE__.metadata/1)}
  end

  def metadata(%{opts: opts}) do
    case opts[:actor] do
      %{id: id} -> %{"authorization" => "Bearer #{id}"}
      _ -> %{}
    end
  end
end

defmodule AshGrpc.Test.E2E.Remote do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshGrpc.Test.E2E.RemoteBook
    resource AshGrpc.Test.E2E.RemoteNote
  end
end

defmodule AshGrpc.Test.E2E.RemoteBook do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.E2E.Remote,
    data_layer: AshGrpc.DataLayer

  grpc_remote do
    client AshGrpc.Test.E2E.LibraryClient
    message AshGrpc.Test.E2E.Proto.V1.Book
    page_size 2

    read :list_books, filter: [:author, :status]
    get :get_book, by: :id
    create :create_book
    update :update_book, update_mask: :update_mask
    destroy :delete_book
  end

  attributes do
    uuid_primary_key :id, public?: true, writable?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :author, :string, public?: true
    attribute :pages, :integer, public?: true
    attribute :status, :atom, public?: true, constraints: [one_of: [:draft, :published]]
    attribute :tags, {:array, :string}, public?: true, default: []
    attribute :inserted_at, :utc_datetime_usec, public?: true, writable?: false
    attribute :headline, :string, public?: true, writable?: false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :author, :pages, :status, :tags]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:title, :author, :pages, :status, :tags]
    end
  end

  calculations do
    calculate :long?, :boolean, expr(pages > 300)
  end

  code_interface do
    define :create, args: [:title]
    define :get, action: :read, get_by: [:id]
  end
end

defmodule AshGrpc.Test.E2E.RemoteNote do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.E2E.Remote,
    data_layer: AshGrpc.DataLayer

  grpc_remote do
    client AshGrpc.Test.E2E.LibraryClient
    message AshGrpc.Test.E2E.Proto.V1.Note

    read :list_notes
    get :get_note, by: :id
    create :create_note
    update :update_note, update_mask: :update_mask
    destroy :delete_note
  end

  attributes do
    uuid_primary_key :id, public?: true, writable?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :owner_id, :string, public?: true, writable?: false
  end

  actions do
    defaults [:read, :destroy, create: [:body]]

    update :update do
      primary? true
      require_atomic? false
      accept [:body]
    end
  end
end
