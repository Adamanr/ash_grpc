defmodule AshGrpc.Test.Remote.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshGrpc.Test.Remote.Ticket
    resource AshGrpc.Test.Remote.StrictTicket
    resource AshGrpc.Test.Remote.SandboxTicket
    resource AshGrpc.Test.Remote.Ops
  end
end

defmodule AshGrpc.Test.Remote.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Remote.Domain,
    data_layer: AshGrpc.DataLayer

  grpc_remote do
    client(AshGrpc.Test.Remote.Client)
    message AshGrpc.Test.Remote.Proto.Ticket
    fields owner: "owner_id"
    page_size(2)

    metadata(fn %{resource: resource, action: action} ->
      %{"x-resource" => inspect(resource), "x-action" => to_string(action)}
    end)

    read :list_tickets, filter: [:owner, :status]
    get(:get_ticket, by: :id)
    create :create_ticket, request: :ticket
    update :update_ticket, request: :ticket, update_mask: :update_mask
    destroy :delete_ticket
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:id, :title, :owner, :status, :priority, :description, :labels]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:title, :status, :priority, :description, :labels]
    end
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      default &AshGrpc.Test.Remote.Ticket.new_id/0
    end

    attribute :title, :string, public?: true
    attribute :owner, :string, public?: true
    attribute :status, :atom, public?: true, constraints: [one_of: [:open, :closed]]
    attribute :priority, :integer, public?: true, default: 0
    attribute :created_at, :utc_datetime, public?: true
    attribute :description, :string, public?: true
    attribute :labels, {:array, :string}, public?: true, default: []
  end

  calculations do
    calculate :urgent?, :boolean, expr(priority >= 5)
  end

  def new_id, do: "t" <> Integer.to_string(System.unique_integer([:positive]))
end

defmodule AshGrpc.Test.Remote.StrictTicket do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Remote.Domain,
    data_layer: AshGrpc.DataLayer

  grpc_remote do
    client(AshGrpc.Test.Remote.Client)
    message AshGrpc.Test.Remote.Proto.Ticket
    strict_filters?(true)
    read :list_tickets, filter: [:owner_id]
  end

  actions do
    defaults [:read]
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :owner_id, :string, public?: true
  end
end

defmodule AshGrpc.Test.Remote.SandboxTicket do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.Test.Remote.Domain,
    data_layer: AshGrpc.DataLayer

  grpc_remote do
    client(AshGrpc.Test.Remote.SandboxClient)
    message AshGrpc.Test.Remote.Proto.Ticket
    page_size(3)
    max_pages(2)
    read :list_tickets, filter: [:owner_id]
    create :create_ticket, request: :ticket
  end

  actions do
    defaults [:read, create: [:id, :title, :owner_id]]
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :owner_id, :string, public?: true
  end
end

defmodule AshGrpc.Test.Remote.Ops do
  @moduledoc false
  # Generic actions calling the remote service through AshGrpc.Rpc.
  use Ash.Resource, domain: AshGrpc.Test.Remote.Domain

  actions do
    action :escalate, :map do
      argument :ticket_id, :string, allow_nil?: false
      argument :level, :integer, default: 1
      run {AshGrpc.Rpc, client: AshGrpc.Test.Remote.Client, rpc: :escalate}
    end

    action :escalate_note, :string do
      argument :ticket_id, :string, allow_nil?: false
      argument :level, :integer, default: 1
      run {AshGrpc.Rpc, client: AshGrpc.Test.Remote.Client, rpc: :escalate, response: :note}
    end

    action :escalate_ticket, :struct do
      constraints instance_of: AshGrpc.Test.Remote.Ticket
      argument :id, :string, allow_nil?: false

      run {AshGrpc.Rpc,
           client: AshGrpc.Test.Remote.Client,
           rpc: "Escalate",
           request: &%{ticket_id: &1.arguments.id, level: 2},
           response: [:ticket]}
    end

    action :priority_after, :integer do
      argument :ticket_id, :string, allow_nil?: false

      run {AshGrpc.Rpc,
           client: AshGrpc.Test.Remote.Client,
           rpc: :escalate,
           request: fn input, _context -> %{ticket_id: input.arguments.ticket_id, level: 1} end,
           response: fn response -> {:ok, response.ticket.priority} end}
    end

    action :who_am_i, :map do
      run {AshGrpc.Rpc,
           client: AshGrpc.Test.Remote.Client,
           rpc: :who_am_i,
           metadata: fn %{tenant: tenant} -> %{"x-tenant" => to_string(tenant)} end}
    end

    action :ping do
      run {AshGrpc.Rpc, client: AshGrpc.Test.Remote.OpsSandboxClient, rpc: :who_am_i}
    end
  end
end
