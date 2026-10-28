defmodule Library.Book do
  @moduledoc "A book of the catalogue."
  use Ash.Resource,
    domain: Library,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true, constraints: [min_length: 1]
    attribute :author, :string, public?: true
    attribute :genre, Library.Genre, public?: true
    attribute :copies, :integer, default: 1, public?: true, constraints: [min: 0]
    attribute :added_by, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  actions do
    defaults [:read, :destroy, update: [:title, :author, :genre, :copies]]

    create :create do
      primary? true
      accept [:title, :author, :genre, :copies]
      change set_attribute(:added_by, actor(:name))
    end

    read :search do
      argument :author, :string
      argument :genre, Library.Genre

      filter expr(
               (is_nil(^arg(:author)) or author == ^arg(:author)) and
                 (is_nil(^arg(:genre)) or genre == ^arg(:genre))
             )

      pagination keyset?: true, required?: false, countable: true, max_page_size: 100
    end

    action :count_available, :integer do
      run fn _input, context ->
        books = Ash.read!(__MODULE__, Ash.Context.to_opts(context))
        {:ok, books |> Enum.map(& &1.copies) |> Enum.sum()}
      end
    end
  end

  policies do
    policy action_type([:read, :action]) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  grpc do
    fields [:id, :title, :author, :genre, :copies, :added_by, :inserted_at]

    rpc :get_book, :read, kind: :get
    rpc :list_books, :search
    rpc :watch_books, :read, kind: :server_stream
    rpc :create_book, :create
    rpc :update_book, :update, update_mask?: true
    rpc :delete_book, :destroy
    rpc :count_available, :count_available
  end
end
