defmodule AshGrpc.Resource.Reserved do
  @moduledoc "Reserved field numbers and names of a resource message (the `reserved` DSL entity)."

  defstruct [:__identifier__, :__spark_metadata__, numbers: [], names: []]

  @type t :: %__MODULE__{
          numbers: [pos_integer() | Range.t() | {pos_integer(), pos_integer() | :max}],
          names: [String.t() | atom()]
        }

  @doc false
  def schema do
    [
      numbers: [
        type: {:list, :any},
        default: [],
        doc: "Numbers that must never be used again: integers, ranges (`4..9`) or `{4, :max}`."
      ],
      names: [
        type: {:list, {:or, [:string, :atom]}},
        default: [],
        doc: "Field names that must never be used again."
      ]
    ]
  end

  @doc false
  @spec to_ir(t()) :: [AshGrpc.Proto.IR.reserved_number()]
  def to_ir(%__MODULE__{numbers: numbers}) do
    Enum.map(numbers, fn
      %Range{first: first, last: last} when first == last -> first
      %Range{first: first, last: last} -> {first, last}
      other -> other
    end)
  end

  @doc false
  @spec reserved?(AshGrpc.Proto.IR.reserved_number(), integer()) :: boolean()
  def reserved?(number, number) when is_integer(number), do: true
  def reserved?({first, :max}, number), do: number >= first
  def reserved?({first, last}, number), do: number >= first and number <= last
  def reserved?(_, _), do: false
end
