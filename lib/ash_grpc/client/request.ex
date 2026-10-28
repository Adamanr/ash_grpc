defmodule AshGrpc.Client.Request do
  @moduledoc """
  Builds request structs from plain maps.

  `build(Billing.V1.ChargeRequest, %{amount: 100, card: %{token: "x"}})` returns
  `%Billing.V1.ChargeRequest{amount: 100, card: %Billing.V1.Card{token: "x"}}`: nested maps are
  converted for embedded message fields (singular, repeated, map values and oneof members
  given as `{field, value}`). Keys must be atoms or strings naming existing fields; string keys
  are only matched against known field names, never converted with `String.to_atom/1`.
  """

  @doc "Converts `value` (a struct of `module`, or a map/keyword list) into a `module` struct."
  @spec build(module(), struct() | map() | keyword()) :: {:ok, struct()} | {:error, Exception.t()}
  def build(module, %module{} = struct), do: {:ok, struct}

  def build(module, %other{}) do
    {:error,
     ArgumentError.exception("expected a #{inspect(module)} request, got a #{inspect(other)}")}
  end

  def build(module, value) when is_map(value) or is_list(value) do
    {:ok, do_build(module, value)}
  rescue
    error in [ArgumentError] -> {:error, error}
    error in [KeyError] -> {:error, ArgumentError.exception(Exception.message(error))}
  end

  def build(module, value) do
    {:error,
     ArgumentError.exception(
       "expected a #{inspect(module)} struct or a map, got: #{inspect(value)}"
     )}
  end

  defp do_build(module, %module{} = struct), do: struct

  defp do_build(module, value) do
    props = module.__message_props__()
    fields = Map.new(props.field_props, fn {_, fp} -> {fp.name_atom, fp} end)

    oneofs =
      Map.new(props.oneof, fn {name, _index} -> {name, true} end)

    known =
      module.__struct__()
      |> Map.keys()
      |> Map.new(&{Atom.to_string(&1), &1})

    attrs =
      Enum.map(value, fn {key, val} ->
        key = key_atom(module, known, key)

        cond do
          Map.has_key?(oneofs, key) -> {key, convert_oneof(val, fields)}
          fp = fields[key] -> {key, convert(fp, val)}
          true -> {key, val}
        end
      end)

    struct!(module, attrs)
  end

  defp key_atom(module, known, key) when is_binary(key) do
    case known do
      %{^key => atom} -> atom
      _ -> raise ArgumentError, "unknown field #{inspect(key)} for #{inspect(module)}"
    end
  end

  defp key_atom(_module, _known, key) when is_atom(key), do: key

  defp convert_oneof({field, val}, fields) when is_atom(field) do
    case fields[field] do
      nil -> {field, val}
      fp -> {field, convert(fp, val)}
    end
  end

  defp convert_oneof(other, _fields), do: other

  defp convert(%{map?: true, type: entry}, val) when is_map(val) do
    value_fp =
      entry.__message_props__().field_props
      |> Map.values()
      |> Enum.find(&(&1.name_atom == :value))

    Map.new(val, fn {k, v} -> {k, convert(value_fp, v)} end)
  end

  defp convert(%{repeated?: true, embedded?: true, type: type}, val) when is_list(val) do
    Enum.map(val, &message(type, &1))
  end

  defp convert(%{embedded?: true, type: type}, val), do: message(type, val)
  defp convert(_fp, val), do: val

  defp message(type, val) when is_map(val) and not is_struct(val), do: do_build(type, val)
  defp message(_type, val), do: val
end
