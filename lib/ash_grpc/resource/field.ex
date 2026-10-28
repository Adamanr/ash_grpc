defmodule AshGrpc.Resource.Field do
  @moduledoc """
  Per-field tuning of a resource message (the `field` DSL entity).

  `name` refers to an attribute, calculation, aggregate or relationship of the
  resource that is part of the message (see the `fields` option).
  """

  defstruct [
    :name,
    :number,
    :proto_name,
    :representation,
    :doc,
    :json_name,
    :__identifier__,
    :__spark_metadata__,
    deprecated?: false,
    options: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          number: pos_integer() | nil,
          proto_name: String.t() | nil,
          representation: AshGrpc.Proto.IR.field_type() | nil,
          doc: String.t() | nil,
          json_name: String.t() | nil,
          deprecated?: boolean(),
          options: [{atom() | String.t(), term()}]
        }

  @doc false
  def schema do
    [
      name: [
        type: :atom,
        required: true,
        doc: "The attribute, calculation, aggregate or relationship to tune."
      ],
      number: [
        type: :pos_integer,
        doc:
          "Explicit field number. Wins over the lock file. Must be unique, not reserved and outside 19000..19999."
      ],
      proto_name: [
        type: :string,
        doc:
          "Field name in the `.proto`. Defaults to the Ash name with a trailing `?`/`!` removed."
      ],
      representation: [
        type: :any,
        doc: """
        Overrides the type mapping: a scalar (`:string`, `:int32`, ...), `{:message, "full.Name"}` or
        `{:enum, "full.Name"}`. Required for types without a default mapping (`:term`, `:function`).
        """
      ],
      doc: [type: :string, doc: "Field comment. Defaults to the Ash description."],
      deprecated?: [type: :boolean, default: false, doc: "Marks the field `[deprecated = true]`."],
      json_name: [type: :string, doc: "Overrides the JSON name of the field."],
      options: [
        type: {:list, {:tuple, [{:or, [:atom, :string]}, :any]}},
        default: [],
        doc: ~S|Extra field options, e.g. `[{"(validate.rules).string.min_len", 1}]`.|
      ]
    ]
  end
end
