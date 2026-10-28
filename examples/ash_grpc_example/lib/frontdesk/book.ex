defmodule Frontdesk.Book do
  @moduledoc "A book of the library, read and written through the library's gRPC API."
  use Ash.Resource,
    domain: Frontdesk,
    data_layer: AshGrpc.DataLayer

  grpc_remote do
    client Frontdesk.LibraryClient
    message Frontdesk.Proto.Book
    page_size 50

    read :list_books, filter: [:author, :genre]
    get :get_book, by: :id
    create :create_book
    update :update_book, update_mask: :update_mask
    destroy :delete_book
  end

  attributes do
    uuid_primary_key :id, public?: true, writable?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :author, :string, public?: true
    attribute :genre, :atom, public?: true, constraints: [one_of: [:fiction, :science, :history]]
    attribute :copies, :integer, public?: true
    attribute :added_by, :string, public?: true, writable?: false
    attribute :inserted_at, :utc_datetime_usec, public?: true, writable?: false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :author, :genre, :copies]
    end

    update :restock do
      require_atomic? false
      argument :copies, :integer, allow_nil?: false
      # the remote data layer has no atomic updates: compute the new value from the record
      change fn changeset, _context ->
        copies = changeset.data.copies || 0
        added = Ash.Changeset.get_argument(changeset, :copies)
        Ash.Changeset.change_attribute(changeset, :copies, copies + added)
      end
    end
  end

  calculations do
    calculate :available?, :boolean, expr(copies > 0)
  end
end
