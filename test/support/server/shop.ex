defmodule AshGrpc.Test.Server.Shop do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  grpc do
    package "ashgrpc.test.shop.v1"
    file "ashgrpc/test/shop/v1/shop.proto"
    module_prefix AshGrpc.Test.Server.Proto.V1

    service "ShopService"
    service "NotesService", resources: [AshGrpc.Test.Server.Note]
    service "DocsService", resources: [AshGrpc.Test.Server.Doc]
  end

  resources do
    resource AshGrpc.Test.Server.Item
    resource AshGrpc.Test.Server.Note
    resource AshGrpc.Test.Server.Doc
  end
end

defmodule AshGrpc.Test.Server.Item do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Server.Shop,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :price, :integer, public?: true, constraints: [min: 0]

    attribute :status, :atom,
      constraints: [one_of: [:draft, :active]],
      default: :draft,
      public?: true

    attribute :tags, {:array, :string}, public?: true
    attribute :category, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  calculations do
    calculate :label, :string, expr(name <> "!"), public?: true
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:name, :price, :status, :tags, :category],
      update: [:name, :price, :status, :tags, :category]
    ]

    read :by_name do
      get? true
      argument :name, :string, allow_nil?: false
      filter expr(name == ^arg(:name))
    end

    read :keyset do
      argument :category, :string
      filter expr(is_nil(^arg(:category)) or category == ^arg(:category))
      pagination keyset?: true, required?: false, countable: true, max_page_size: 50
    end

    read :offset do
      pagination offset?: true, required?: false, countable: false
    end

    destroy :archive do
      argument :reason, :string
    end

    action :echo, :string do
      argument :message, :string, allow_nil?: false
      run fn input, _ -> {:ok, input.arguments.message} end
    end

    action :noop do
      run fn _, _ -> :ok end
    end

    action :slow, :string do
      argument :ms, :integer, allow_nil?: false

      run fn input, _ ->
        Process.sleep(input.arguments.ms)
        {:ok, "done"}
      end
    end

    action :names, {:array, :string} do
      run fn _, ctx ->
        {:ok,
         __MODULE__ |> Ash.read!(Ash.Context.to_opts(ctx)) |> Enum.map(& &1.name) |> Enum.sort()}
      end
    end

    action :boom, :string do
      run fn _, _ -> raise "secret detail" end
    end

    action :whoami, :string do
      run fn _, ctx -> {:ok, (ctx.actor && ctx.actor.id) || "anonymous"} end
    end
  end

  grpc do
    fields [:id, :name, :price, :status, :tags, :category, :inserted_at, :label]

    rpc :get_item, :read, get_by: [:id], read_mask?: true
    rpc :get_item_by_name, :by_name
    rpc :list_items, :keyset, filter?: true, read_mask?: true
    rpc :list_items_offset, :offset
    rpc :list_items_plain, :read, kind: :list
    rpc :watch_items, :read, kind: :server_stream
    rpc :create_item, :create
    rpc :create_item_wrapped, :create, input: :wrapped
    rpc :update_item, :update, update_mask?: true
    rpc :delete_item, :destroy
    rpc :archive_item, :archive, return_destroyed?: true
    rpc :import_items, :create, kind: :client_stream
    rpc :echo, :echo
    rpc :noop, :noop
    rpc :slow, :slow
    rpc :names, :names
    rpc :boom, :boom
    rpc :whoami, :whoami
    rpc :chat, :echo, kind: :bidi_stream, handler: AshGrpc.Test.Server.ChatHandler
  end
end

defmodule AshGrpc.Test.Server.Note do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Server.Shop,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :owner_id, :string, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:body]
      change set_attribute(:owner_id, actor(:id))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end
  end

  grpc do
    rpc :create_note, :create
    rpc :list_notes, :read
  end
end

defmodule AshGrpc.Test.Server.Doc do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Server.Shop,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  multitenancy do
    strategy :attribute
    attribute :org
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :org, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, create: [:title]]
  end

  grpc do
    rpc :create_doc, :create
    rpc :list_docs, :read
  end
end

defmodule AshGrpc.Test.Server.ChatHandler do
  @moduledoc false
  @behaviour AshGrpc.Server.RpcHandler

  @impl true
  def handle_rpc(requests, stream, ctx) do
    Enum.each(requests, fn request ->
      GRPC.Server.send_reply(stream, struct(ctx.output_module, value: "re:" <> request.message))
    end)
  end
end

defmodule AshGrpc.Test.Server.Auth do
  @moduledoc false
  @behaviour AshGrpc.Actor

  @impl true
  def get_actor(metadata, _stream) do
    case metadata["authorization"] do
      nil -> {:ok, nil}
      "Bearer bad" -> {:error, :unauthenticated}
      "Bearer " <> id -> {:ok, %{id: id}}
      _ -> {:error, :unauthenticated}
    end
  end
end

defmodule AshGrpc.Test.Server.Endpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    otp_app: :ash_grpc,
    domains: [AshGrpc.Test.Server.Shop],
    lock_path: "test/support/server/ash_grpc.lock.json",
    interceptors: [
      AshGrpc.Interceptors.Logger,
      {AshGrpc.Interceptors.Actor, from: AshGrpc.Test.Server.Auth},
      AshGrpc.Interceptors.Tenant
    ],
    reflection: true,
    health: true
end

defmodule AshGrpc.Test.Server.Client do
  @moduledoc false
  use AshGrpc.Client,
    otp_app: :ash_grpc,
    services: [
      AshGrpc.Test.Server.Proto.V1.ShopService.Service,
      AshGrpc.Test.Server.Proto.V1.NotesService.Service,
      AshGrpc.Test.Server.Proto.V1.DocsService.Service,
      AshGrpc.Server.Health.V1.Health.Service,
      Grpc.Reflection.V1.ServerReflection.Service
    ]
end
