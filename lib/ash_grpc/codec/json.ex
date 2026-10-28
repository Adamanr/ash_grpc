defmodule AshGrpc.Codec.Json do
  @moduledoc """
  Conversions between Elixir terms and `google.protobuf.Struct` /
  `google.protobuf.Value` / `google.protobuf.ListValue` (and JSON strings).

  Encoding normalizes values to JSON: map keys become strings, atoms become
  strings (except `nil`/`true`/`false`), `Decimal`s and `Ash.CiString`s become
  strings, dates and times ISO-8601 strings, tuples lists. Other structs must
  implement `Jason.Encoder`.

  Decoding produces string-keyed maps. Numbers are doubles on the wire; whole
  numbers in the safe integer range (±2^53) are decoded as integers.
  """

  alias Google.Protobuf.{ListValue, Struct, Value}

  @max_safe_integer 9_007_199_254_740_992

  @doc "Encodes a map (or keyword list) into a `google.protobuf.Struct`."
  @spec to_struct(map() | Keyword.t()) :: {:ok, Struct.t()} | {:error, term()}
  def to_struct(value) when is_list(value) do
    if Keyword.keyword?(value),
      do: to_struct(Map.new(value)),
      else: {:error, {:invalid_value, value, "expected a map"}}
  end

  def to_struct(value) when is_map(value) and not is_struct(value) do
    with {:ok, fields} <- encode_fields(value), do: {:ok, %Struct{fields: fields}}
  end

  def to_struct(value) when is_struct(value) do
    with {:ok, normalized} <- normalize(value) do
      if is_map(normalized),
        do: to_struct(normalized),
        else: {:error, {:invalid_value, value, "expected a map"}}
    end
  end

  def to_struct(value), do: {:error, {:invalid_value, value, "expected a map"}}

  @doc "Encodes any JSON-like term into a `google.protobuf.Value`."
  @spec to_value(term()) :: {:ok, Value.t()} | {:error, term()}
  def to_value(nil), do: {:ok, %Value{kind: {:null_value, :NULL_VALUE}}}
  def to_value(value) when is_boolean(value), do: {:ok, %Value{kind: {:bool_value, value}}}

  def to_value(value) when is_integer(value),
    do: {:ok, %Value{kind: {:number_value, value * 1.0}}}

  def to_value(value) when is_float(value), do: {:ok, %Value{kind: {:number_value, value}}}

  def to_value(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, %Value{kind: {:string_value, value}}},
      else: {:error, {:invalid_value, value, "strings must be valid UTF-8"}}
  end

  def to_value(value) when is_atom(value), do: to_value(Atom.to_string(value))

  def to_value(value) when is_list(value) do
    if value != [] and Keyword.keyword?(value) do
      to_value(Map.new(value))
    else
      with {:ok, values} <- map_ok(value, &to_value/1) do
        {:ok, %Value{kind: {:list_value, %ListValue{values: values}}}}
      end
    end
  end

  def to_value(value) when is_tuple(value), do: to_value(Tuple.to_list(value))

  def to_value(value) when is_map(value) and not is_struct(value) do
    with {:ok, struct} <- to_struct(value), do: {:ok, %Value{kind: {:struct_value, struct}}}
  end

  def to_value(value) when is_struct(value) do
    with {:ok, normalized} <- normalize(value), do: to_value(normalized)
  end

  def to_value(value), do: {:error, {:invalid_value, value, "not representable as JSON"}}

  @doc "Decodes a `google.protobuf.Struct` into a string-keyed map."
  @spec from_struct(Struct.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  def from_struct(nil), do: {:ok, nil}

  def from_struct(%Struct{fields: fields}) do
    fields
    |> map_ok(fn {key, value} ->
      with {:ok, value} <- from_value(value), do: {:ok, {key, value}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  def from_struct(other), do: {:error, {:invalid_value, other, "expected google.protobuf.Struct"}}

  @doc "Decodes a `google.protobuf.Value` into a JSON-like term."
  @spec from_value(Value.t() | nil) :: {:ok, term()} | {:error, term()}
  def from_value(nil), do: {:ok, nil}
  def from_value(%Value{kind: nil}), do: {:ok, nil}
  def from_value(%Value{kind: {:null_value, _}}), do: {:ok, nil}
  def from_value(%Value{kind: {:bool_value, value}}), do: {:ok, value}
  def from_value(%Value{kind: {:string_value, value}}), do: {:ok, value}
  def from_value(%Value{kind: {:number_value, value}}), do: {:ok, number(value)}
  def from_value(%Value{kind: {:struct_value, struct}}), do: from_struct(struct)
  def from_value(%Value{kind: {:list_value, list}}), do: from_list(list)
  def from_value(other), do: {:error, {:invalid_value, other, "expected google.protobuf.Value"}}

  @doc "Decodes a `google.protobuf.ListValue` into a list."
  @spec from_list(ListValue.t() | nil) :: {:ok, list() | nil} | {:error, term()}
  def from_list(nil), do: {:ok, nil}
  def from_list(%ListValue{values: values}), do: map_ok(values, &from_value/1)

  @doc "Encodes a term as a JSON string."
  @spec encode_string(term()) :: {:ok, String.t()} | {:error, term()}
  def encode_string(value) do
    with {:ok, normalized} <- normalize(value) do
      case Jason.encode(normalized) do
        {:ok, json} -> {:ok, json}
        {:error, error} -> {:error, {:invalid_value, value, Exception.message(error)}}
      end
    end
  end

  @doc "Decodes a JSON string."
  @spec decode_string(String.t()) :: {:ok, term()} | {:error, term()}
  def decode_string(""), do: {:ok, nil}

  def decode_string(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, {:invalid_value, json, "invalid JSON"}}
    end
  end

  @doc "Normalizes a term into plain JSON data (string keys, no structs/atoms/tuples)."
  @spec normalize(term()) :: {:ok, term()} | {:error, term()}
  def normalize(value) when is_nil(value) or is_boolean(value) or is_number(value),
    do: {:ok, value}

  def normalize(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, {:invalid_value, value, "strings must be valid UTF-8"}}
  end

  def normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def normalize(%Decimal{} = value), do: {:ok, Decimal.to_string(value, :normal)}
  def normalize(%Ash.CiString{} = value), do: {:ok, to_string(value)}
  def normalize(%Ash.Union{value: value}), do: normalize(value)
  def normalize(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  def normalize(%NaiveDateTime{} = value), do: {:ok, NaiveDateTime.to_iso8601(value)}
  def normalize(%Date{} = value), do: {:ok, Date.to_iso8601(value)}
  def normalize(%Time{} = value), do: {:ok, Time.to_iso8601(value)}
  def normalize(%Duration{} = value), do: {:ok, Duration.to_iso8601(value)}
  def normalize(value) when is_tuple(value), do: normalize(Tuple.to_list(value))

  def normalize(value) when is_list(value) do
    if value != [] and Keyword.keyword?(value),
      do: normalize(Map.new(value)),
      else: map_ok(value, &normalize/1)
  end

  def normalize(value) when is_struct(value) do
    if Jason.Encoder.impl_for(value) in [nil, Jason.Encoder.Any],
      do: {:error, {:invalid_value, value, "structs must implement Jason.Encoder"}},
      else: json_roundtrip(value)
  end

  def normalize(value) when is_map(value) do
    value
    |> map_ok(fn {key, value} ->
      with {:ok, key} <- normalize_key(key), {:ok, value} <- normalize(value) do
        {:ok, {key, value}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  def normalize(value), do: {:error, {:invalid_value, value, "not representable as JSON"}}

  defp json_roundtrip(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, error} -> {:error, {:invalid_value, value, Exception.message(error)}}
    end
  end

  defp normalize_key(key) when is_binary(key) or is_atom(key) or is_number(key),
    do: {:ok, to_string(key)}

  defp normalize_key(key), do: {:error, {:invalid_value, key, "map keys must be strings"}}

  defp encode_fields(map) do
    map
    |> map_ok(fn {key, value} ->
      with {:ok, key} <- normalize_key(key), {:ok, value} <- to_value(value) do
        {:ok, {key, value}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp number(value) when is_float(value) do
    if value == Float.round(value) and abs(value) <= @max_safe_integer,
      do: trunc(value),
      else: value
  end

  defp number(value), do: value

  defp map_ok(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
