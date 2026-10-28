defmodule AshGrpc.Domain.Service do
  @moduledoc """
  A gRPC service of a domain (the domain `service` DSL entity).

  An rpc is assigned to the first service that applies, in this order:

    1. the rpc's own `service:` option,
    2. a service listing the rpc name in `rpcs`,
    3. a service listing the rpc's resource in `resources`,
    4. a service with neither `rpcs` nor `resources` (the domain's default service),
    5. `"<Name>Service"` derived from the package (`myapp.accounts.v1` → `AccountsService`).
  """

  defstruct [
    :name,
    :doc,
    :__identifier__,
    :__spark_metadata__,
    rpcs: [],
    resources: [],
    options: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          doc: String.t() | nil,
          rpcs: [atom()],
          resources: [module()],
          options: [{atom() | String.t(), term()}]
        }

  @doc "Returns true if the service is a catch-all (no `rpcs` and no `resources`)."
  @spec default?(t()) :: boolean()
  def default?(%__MODULE__{rpcs: [], resources: []}), do: true
  def default?(%__MODULE__{}), do: false

  @doc false
  def schema do
    [
      name: [
        type: :string,
        required: true,
        doc: "The service name (PascalCase, ending in `Service`)."
      ],
      rpcs: [
        type: {:list, :atom},
        default: [],
        doc: "Rpc names (as declared in resources) that belong to this service."
      ],
      resources: [
        type: {:list, :atom},
        default: [],
        doc: "Resources whose rpcs belong to this service."
      ],
      doc: [type: :string, doc: "Service comment."],
      options: [
        type: {:list, {:tuple, [{:or, [:atom, :string]}, :any]}},
        default: [],
        doc: "Service options."
      ]
    ]
  end
end
