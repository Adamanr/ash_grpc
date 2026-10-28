defmodule AshGrpc.DataLayer.Filter do
  @moduledoc """
  Analysis of Ash filters for push-down to rpc request fields.

  Only equality conditions between an attribute of the resource itself and a literal value,
  combined with `and` at the top level, can be pushed down (`owner_id == "u1" and status ==
  :open`). Everything else is evaluated in memory by `AshGrpc.DataLayer`.
  """

  alias Ash.Query.{BooleanExpression, Ref}
  alias Ash.Query.Operator.Eq

  @doc """
  The top-level equality conditions of `filter`: `%{attribute => value}`. When an attribute is
  compared to several values, the first one wins (the in-memory filter keeps results correct).
  """
  @spec equalities(Ash.Filter.t() | nil) :: %{atom() => term()}
  def equalities(filter) do
    filter
    |> conjuncts()
    |> Enum.flat_map(fn conjunct ->
      case equality(conjunct) do
        {:ok, name, value} -> [{name, value}]
        :error -> []
      end
    end)
    |> Enum.reverse()
    |> Map.new()
  end

  @doc """
  Returns true when every top-level condition of `filter` is an equality on one of the
  `attributes` (so the rpc evaluates the whole filter).
  """
  @spec covered?(Ash.Filter.t() | nil, [atom()]) :: boolean()
  def covered?(filter, attributes) do
    filter
    |> conjuncts()
    |> Enum.all?(fn conjunct ->
      case equality(conjunct) do
        {:ok, name, _value} -> name in attributes
        :error -> false
      end
    end)
  end

  @doc "The top-level `and` operands of a filter."
  @spec conjuncts(Ash.Filter.t() | term()) :: [term()]
  def conjuncts(nil), do: []
  def conjuncts(%Ash.Filter{expression: expression}), do: conjuncts(expression)
  def conjuncts(true), do: []

  def conjuncts(%BooleanExpression{op: :and, left: left, right: right}),
    do: conjuncts(left) ++ conjuncts(right)

  def conjuncts(other), do: [other]

  defp equality(%Eq{left: %Ref{} = ref, right: value}), do: ref_equality(ref, value)
  defp equality(%Eq{left: value, right: %Ref{} = ref}), do: ref_equality(ref, value)
  defp equality(_other), do: :error

  defp ref_equality(
         %Ref{relationship_path: [], attribute: %Ash.Resource.Attribute{name: name}},
         value
       )
       when is_atom(name) do
    if literal?(value), do: {:ok, name, value}, else: :error
  end

  defp ref_equality(_ref, _value), do: :error

  defp literal?(value), do: not Ash.Expr.expr?(value)
end
