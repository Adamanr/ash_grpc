defmodule AshGrpc.Proto.Import.Wire do
  @moduledoc """
  Minimal schema-less protobuf wire parser, used to decode custom option values
  whose types are only known from the imported descriptors (not from compiled
  Elixir modules).
  """

  import Bitwise

  @type field :: {pos_integer(), 0 | 1 | 2 | 5, non_neg_integer() | binary()}

  @doc "Splits an encoded message into `{number, wire_type, raw_value}` triples."
  @spec parse(binary()) :: {:ok, [field()]} | :error
  def parse(binary), do: parse(binary, [])

  @doc "Decodes a packed repeated field payload into raw values of the given wire type."
  @spec unpack(binary(), 0 | 1 | 5) :: {:ok, [non_neg_integer() | binary()]} | :error
  def unpack(binary, wire_type), do: unpack(binary, wire_type, [])

  defp parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse(binary, acc) do
    with {:ok, key, rest} <- varint(binary),
         {:ok, value, rest} <- value(key &&& 7, rest) do
      parse(rest, [{key >>> 3, key &&& 7, value} | acc])
    end
  end

  defp unpack(<<>>, _wire_type, acc), do: {:ok, Enum.reverse(acc)}

  defp unpack(binary, wire_type, acc) do
    case value(wire_type, binary) do
      {:ok, value, rest} -> unpack(rest, wire_type, [value | acc])
      :error -> :error
    end
  end

  defp value(0, binary), do: varint(binary)
  defp value(1, <<value::binary-size(8), rest::binary>>), do: {:ok, value, rest}
  defp value(5, <<value::binary-size(4), rest::binary>>), do: {:ok, value, rest}

  defp value(2, binary) do
    with {:ok, size, rest} <- varint(binary),
         <<value::binary-size(size), rest::binary>> <- rest do
      {:ok, value, rest}
    else
      _ -> :error
    end
  end

  defp value(_wire_type, _binary), do: :error

  defp varint(binary), do: varint(binary, 0, 0)

  defp varint(<<1::1, chunk::7, rest::binary>>, shift, acc) when shift < 64,
    do: varint(rest, shift + 7, acc ||| chunk <<< shift)

  defp varint(<<0::1, chunk::7, rest::binary>>, shift, acc),
    do: {:ok, acc ||| chunk <<< shift, rest}

  defp varint(_binary, _shift, _acc), do: :error
end
