defmodule AshGrpc.Domain.Option do
  @moduledoc "A file-level proto option (the domain `option` DSL entity)."

  defstruct [:name, :value, :__identifier__, :__spark_metadata__]

  @type t :: %__MODULE__{name: atom() | String.t(), value: term()}

  @doc false
  def schema do
    [
      name: [
        type: {:or, [:atom, :string]},
        required: true,
        doc: ~S|The option name, e.g. `:go_package` or `"(my.ext).opt"`.|
      ],
      value: [
        type: :any,
        required: true,
        doc: "The option value (string, number, boolean, atom for enum constants, or map)."
      ]
    ]
  end
end
