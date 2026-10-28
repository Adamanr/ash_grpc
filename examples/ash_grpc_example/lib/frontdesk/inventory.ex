defmodule Frontdesk.Inventory do
  @moduledoc "Generic actions that call single rpcs of the library service."
  use Ash.Resource, domain: Frontdesk

  actions do
    action :count_available, :integer do
      run {AshGrpc.Rpc, client: Frontdesk.LibraryClient, rpc: :count_available, response: :value}
    end
  end
end
