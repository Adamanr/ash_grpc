defmodule AshGrpc.Resource.Rpc do
  @moduledoc """
  An rpc backed by a resource action (the `rpc` DSL entity).

  `kind` is resolved by `AshGrpc.Resource.Info.rpcs/1` when it was omitted in the DSL:
  `:read` actions become `:get` (when the action is `get?` or `get_by` is set) or `:list`,
  `:create`/`:update`/`:destroy` keep their type, generic actions become `:action`.
  """

  @kinds [
    :get,
    :list,
    :server_stream,
    :create,
    :client_stream,
    :update,
    :destroy,
    :action,
    :bidi_stream
  ]

  defstruct [
    :name,
    :action,
    :kind,
    :get_by,
    :request_message,
    :response_message,
    :handler,
    :idempotency_level,
    :service,
    :doc,
    :load,
    :__identifier__,
    :__spark_metadata__,
    update_mask?: false,
    read_mask?: false,
    filter?: false,
    return_destroyed?: false,
    input: :flat,
    deprecated?: false,
    options: []
  ]

  @type kind ::
          :get
          | :list
          | :server_stream
          | :create
          | :client_stream
          | :update
          | :destroy
          | :action
          | :bidi_stream

  @type t :: %__MODULE__{
          name: atom(),
          action: atom(),
          kind: kind() | nil,
          get_by: [atom()] | nil,
          request_message: String.t() | module() | nil,
          response_message: String.t() | module() | nil,
          handler: module() | nil,
          idempotency_level: :no_side_effects | :idempotent | :unknown | nil,
          service: String.t() | nil,
          doc: String.t() | nil,
          load: term(),
          update_mask?: boolean(),
          read_mask?: boolean(),
          filter?: boolean(),
          return_destroyed?: boolean(),
          input: :flat | :wrapped,
          deprecated?: boolean(),
          options: [{atom() | String.t(), term()}]
        }

  @doc "All rpc kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Action types a kind can be backed by (`:any` for `:bidi_stream`)."
  @spec action_types(kind()) :: [atom()] | :any
  def action_types(kind) when kind in [:get, :list, :server_stream], do: [:read]
  def action_types(kind) when kind in [:create, :client_stream], do: [:create]
  def action_types(:update), do: [:update]
  def action_types(:destroy), do: [:destroy]
  def action_types(:action), do: [:action]
  def action_types(:bidi_stream), do: :any

  @doc "The kind derived from an action when `kind` is omitted."
  @spec default_kind(Ash.Resource.Actions.action(), [atom()] | nil) :: kind()
  def default_kind(%{type: :read} = action, get_by) do
    if Map.get(action, :get?) || get_by not in [nil, []], do: :get, else: :list
  end

  def default_kind(%{type: :action}, _get_by), do: :action
  def default_kind(%{type: type}, _get_by), do: type

  @doc false
  def schema do
    [
      name: [
        type: :atom,
        required: true,
        doc: "The rpc name. The proto name is its PascalCase form (`:get_user` → `GetUser`)."
      ],
      action: [type: :atom, required: true, doc: "The resource action backing the rpc."],
      kind: [
        type: {:one_of, @kinds},
        doc: """
        The rpc shape. Derived from the action type when omitted (`read` → `:get` if the action
        is `get?` or `get_by` is set, otherwise `:list`). `:server_stream` (read),
        `:client_stream` (bulk create) and `:bidi_stream` (any action, requires `handler`)
        must be explicit.
        """
      ],
      get_by: [
        type: {:list, :atom},
        doc:
          "Attributes/arguments identifying the record for `:get`. Defaults to the primary key unless the action is `get?`."
      ],
      update_mask?: [
        type: :boolean,
        default: false,
        doc: "Adds a `google.protobuf.FieldMask update_mask` to an `:update` request (AIP-134)."
      ],
      read_mask?: [
        type: :boolean,
        default: false,
        doc: "Adds a `google.protobuf.FieldMask read_mask` to read requests (AIP-157)."
      ],
      filter?: [
        type: :boolean,
        default: false,
        doc: "Adds `filter` and `order_by` strings to a `:list` request (AIP-160/132)."
      ],
      return_destroyed?: [
        type: :boolean,
        default: false,
        doc: "`:destroy` returns the destroyed record instead of `google.protobuf.Empty`."
      ],
      input: [
        type: {:one_of, [:flat, :wrapped]},
        default: :flat,
        doc: """
        `:flat` puts accepted attributes and arguments directly into the request; `:wrapped`
        puts the record message into a single field named after the resource
        (`{ User user = 1; }`), arguments stay flat. Only for `:create`, `:update`, `:client_stream`.
        """
      ],
      request_message: [
        type: {:or, [:string, :atom]},
        doc:
          "A string renames the generated request message; a protobuf module (`use Protobuf`) replaces it."
      ],
      response_message: [
        type: {:or, [:string, :atom]},
        doc:
          "A string renames the generated response message; a protobuf module (`use Protobuf`) replaces it."
      ],
      handler: [
        type: :atom,
        doc:
          "A module that handles the rpc instead of the default handler. Required for `:bidi_stream`."
      ],
      idempotency_level: [
        type: {:one_of, [:no_side_effects, :idempotent, :unknown]},
        doc:
          "Overrides the derived idempotency level (`read` actions → `:no_side_effects`, others unknown)."
      ],
      service: [
        type: :string,
        doc: "The service this rpc belongs to. Overrides the domain `service` configuration."
      ],
      doc: [type: :string, doc: "Rpc comment. Defaults to the action description."],
      deprecated?: [type: :boolean, default: false, doc: "Marks the rpc `deprecated = true`."],
      load: [type: :any, doc: "A load statement applied to records returned by the rpc."],
      options: [
        type: {:list, {:tuple, [{:or, [:atom, :string]}, :any]}},
        default: [],
        doc: "Extra method options."
      ]
    ]
  end
end
