defmodule Frontdesk do
  @moduledoc """
  The consuming side of the example: a front desk application that does not own any data.
  Its books live in the library service and are reached over gRPC:

    * `Frontdesk.Book` is a resource backed by the library service (`AshGrpc.DataLayer`),
    * `Frontdesk.Inventory.count_available/0` calls one rpc (`AshGrpc.Rpc`).

  It only knows the library through its published `.proto` file
  (`priv/protos/library/v1/library.proto`, compiled by `Frontdesk.Proto`).
  """
  use Ash.Domain

  resources do
    resource Frontdesk.Book do
      define :add_book, action: :create, args: [:title]
      define :get_book, action: :read, get_by: [:id]
      define :list_books, action: :read
      define :restock, action: :restock, args: [:copies]
      define :remove_book, action: :destroy
    end

    resource Frontdesk.Inventory do
      define :count_available
    end
  end
end
