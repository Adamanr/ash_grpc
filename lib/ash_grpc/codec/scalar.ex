defmodule AshGrpc.Codec.Scalar do
  @moduledoc """
  Value conversions for scalar-like Ash types and the well-known / `google.type`
  messages they map to (see `AshGrpc.Type.Mapping`).

  `encode/3` takes the (cast) Ash value, the Ash type module (or `nil` when the
  Ash type is unknown, e.g. for imported messages) and the IR field type.
  `decode/3` is the inverse; its results are plain Elixir values that Ash casts.
  """

  alias AshGrpc.Codec.Json
  alias AshGrpc.Type.Known

  @int_ranges %{
    int32: {-2_147_483_648, 2_147_483_647},
    sint32: {-2_147_483_648, 2_147_483_647},
    sfixed32: {-2_147_483_648, 2_147_483_647},
    int64: {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807},
    sint64: {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807},
    sfixed64: {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807},
    uint32: {0, 4_294_967_295},
    fixed32: {0, 4_294_967_295},
    uint64: {0, 18_446_744_073_709_551_615},
    fixed64: {0, 18_446_744_073_709_551_615}
  }

  @int_types Map.keys(@int_ranges)
  @uuid_types [Ash.Type.UUID, Ash.Type.UUIDv7]

  @doc "Encodes a scalar-like Ash value into a protobuf field value."
  @spec encode(term(), module() | nil, AshGrpc.Proto.IR.field_type()) ::
          {:ok, term()} | {:error, term()}
  def encode(nil, _module, _field_type), do: {:ok, nil}

  def encode(value, module, {:message, full_name} = field_type) do
    case Known.wrapper_scalar(full_name) do
      nil ->
        encode_message(value, module, full_name)

      scalar ->
        with {:ok, inner} <- encode(value, module, scalar) do
          {:ok, struct(Known.module(full_name), value: inner)}
        end
    end
    |> tag_error(value, field_type)
  end

  def encode(value, module, field_type), do: encode_scalar(value, module, field_type)

  @doc "Decodes a protobuf field value into a value Ash can cast."
  @spec decode(term(), module() | nil, AshGrpc.Proto.IR.field_type()) ::
          {:ok, term()} | {:error, term()}
  def decode(nil, _module, _field_type), do: {:ok, nil}

  def decode(value, module, {:message, full_name} = field_type) do
    case Known.wrapper_scalar(full_name) do
      nil -> decode_message(value, module, full_name)
      scalar -> decode(Map.get(value, :value), module, scalar)
    end
    |> tag_error(value, field_type)
  end

  def decode(value, module, field_type), do: decode_scalar(value, module, field_type)

  ## scalars

  defp encode_scalar(%Ash.CiString{} = value, module, type),
    do: encode_scalar(to_string(value), module, type)

  defp encode_scalar(value, module, :bytes) when module in @uuid_types and is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, raw} -> {:ok, raw}
      :error -> invalid(value, :bytes, "invalid UUID")
    end
  end

  defp encode_scalar(value, _module, :bytes) when is_binary(value), do: {:ok, value}

  defp encode_scalar(value, _module, :string) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: invalid(value, :string, "strings must be valid UTF-8")
  end

  defp encode_scalar(value, Ash.Type.Module, :string) when is_atom(value),
    do: {:ok, value |> Atom.to_string() |> String.replace_prefix("Elixir.", "")}

  defp encode_scalar(value, _module, :string) when is_atom(value),
    do: {:ok, Atom.to_string(value)}

  defp encode_scalar(value, _module, :string) when is_integer(value),
    do: {:ok, Integer.to_string(value)}

  defp encode_scalar(value, _module, :string) when is_float(value),
    do: {:ok, Float.to_string(value)}

  defp encode_scalar(%Decimal{} = value, _module, :string),
    do: {:ok, Decimal.to_string(value, :normal)}

  defp encode_scalar(%DateTime{} = value, _module, :string),
    do: {:ok, DateTime.to_iso8601(value)}

  defp encode_scalar(%NaiveDateTime{} = value, _module, :string),
    do: {:ok, NaiveDateTime.to_iso8601(value)}

  defp encode_scalar(%Date{} = value, _module, :string), do: {:ok, Date.to_iso8601(value)}
  defp encode_scalar(%Time{} = value, _module, :string), do: {:ok, Time.to_iso8601(value)}

  defp encode_scalar(%Duration{} = value, _module, :string),
    do: {:ok, Duration.to_iso8601(value)}

  defp encode_scalar(value, _module, :string) when is_map(value) or is_list(value),
    do: Json.encode_string(value)

  defp encode_scalar(value, _module, type) when type in @int_types and is_integer(value) do
    {min, max} = Map.fetch!(@int_ranges, type)

    if value >= min and value <= max,
      do: {:ok, value},
      else: invalid(value, type, "out of range")
  end

  defp encode_scalar(value, _module, type) when type in [:double, :float] and is_number(value),
    do: {:ok, value * 1.0}

  defp encode_scalar(value, _module, :bool) when is_boolean(value), do: {:ok, value}

  defp encode_scalar(value, _module, type), do: invalid(value, type, "unexpected value")

  defp decode_scalar(value, module, :bytes) when module in @uuid_types and is_binary(value) do
    case value do
      "" ->
        {:ok, nil}

      raw ->
        case Ecto.UUID.load(raw) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> invalid(value, :bytes, "invalid UUID")
        end
    end
  end

  defp decode_scalar(value, module, :string) when is_binary(value),
    do: decode_string(value, module)

  defp decode_scalar(value, _module, type) when type in @int_types and is_integer(value),
    do: {:ok, value}

  defp decode_scalar(value, _module, type) when type in [:double, :float] and is_number(value),
    do: {:ok, value * 1.0}

  defp decode_scalar(value, _module, :bool) when is_boolean(value), do: {:ok, value}
  defp decode_scalar(value, _module, :bytes) when is_binary(value), do: {:ok, value}
  defp decode_scalar(value, _module, type), do: invalid(value, type, "unexpected value")

  # Strings are kept as strings unless the Ash type needs a richer value;
  # atoms are never created from wire data (Ash casts existing atoms).
  defp decode_string(value, Ash.Type.Integer) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> invalid(value, :string, "invalid integer")
    end
  end

  defp decode_string(value, Ash.Type.Float) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> invalid(value, :string, "invalid float")
    end
  end

  defp decode_string(value, Ash.Type.Decimal) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> invalid(value, :string, "invalid decimal")
    end
  end

  defp decode_string(value, Ash.Type.Date), do: parse(value, &Date.from_iso8601/1)

  defp decode_string(value, module) when module in [Ash.Type.Time, Ash.Type.TimeUsec],
    do: parse(value, &Time.from_iso8601/1)

  defp decode_string(value, Ash.Type.NaiveDatetime),
    do: parse(value, &NaiveDateTime.from_iso8601/1)

  defp decode_string(value, module)
       when module in [Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec, Ash.Type.DateTime] do
    parse(value, fn string ->
      case DateTime.from_iso8601(string) do
        {:ok, datetime, _offset} -> {:ok, datetime}
        error -> error
      end
    end)
  end

  defp decode_string(value, Ash.Type.Duration), do: parse(value, &Duration.from_iso8601/1)

  # modules are sent without the `Elixir.` prefix; Ash resolves existing atoms only
  defp decode_string(<<first, _::binary>> = value, Ash.Type.Module) when first in ?A..?Z,
    do: {:ok, "Elixir." <> value}

  defp decode_string(value, module)
       when module in [Ash.Type.Map, Ash.Type.Struct, Ash.Type.Keyword, Ash.Type.Tuple] or
              module == Ash.Type.Union or module == Ash.Type.Term,
       do: Json.decode_string(value)

  defp decode_string(value, _module), do: {:ok, value}

  defp parse("", _fun), do: {:ok, nil}

  defp parse(value, fun) do
    case fun.(value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> invalid(value, :string, "invalid ISO-8601 value")
    end
  end

  ## messages

  defp encode_message(%DateTime{} = value, _module, "google.protobuf.Timestamp"),
    do: {:ok, Google.Protobuf.from_datetime(value)}

  defp encode_message(%Duration{} = value, _module, "google.protobuf.Duration") do
    {:ok, Google.Protobuf.from_duration(value)}
  rescue
    ArgumentError ->
      invalid(value, "google.protobuf.Duration", "months and years are not allowed")
  end

  defp encode_message(%Date{} = value, _module, "google.type.Date"),
    do: {:ok, %Google.Type.Date{year: value.year, month: value.month, day: value.day}}

  defp encode_message(%Time{} = value, _module, "google.type.TimeOfDay") do
    {microsecond, _} = value.microsecond

    {:ok,
     %Google.Type.TimeOfDay{
       hours: value.hour,
       minutes: value.minute,
       seconds: value.second,
       nanos: microsecond * 1_000
     }}
  end

  defp encode_message(%Decimal{} = value, _module, "google.type.Decimal"),
    do: {:ok, %Google.Type.Decimal{value: Decimal.to_string(value, :normal)}}

  defp encode_message(value, _module, "google.protobuf.Struct"), do: Json.to_struct(value)
  defp encode_message(value, _module, "google.protobuf.Value"), do: Json.to_value(value)

  defp encode_message(value, _module, "google.protobuf.ListValue") when is_list(value) do
    with {:ok, %{kind: {:list_value, list}}} <- Json.to_value(value), do: {:ok, list}
  end

  defp encode_message(%Google.Protobuf.FieldMask{} = value, _module, "google.protobuf.FieldMask"),
    do: {:ok, value}

  defp encode_message(paths, _module, "google.protobuf.FieldMask") when is_list(paths),
    do: {:ok, %Google.Protobuf.FieldMask{paths: Enum.map(paths, &to_string/1)}}

  defp encode_message(%_{} = value, _module, "google.protobuf.Empty"), do: {:ok, value}

  defp encode_message(_value, _module, "google.protobuf.Empty"),
    do: {:ok, %Google.Protobuf.Empty{}}

  defp encode_message(%module{} = value, _type, full_name) do
    if Known.module(full_name) == module,
      do: {:ok, value},
      else: invalid(value, full_name, "unexpected value")
  end

  defp encode_message(value, _module, full_name),
    do: invalid(value, full_name, "unexpected value")

  defp decode_message(%Google.Protobuf.Timestamp{} = value, _module, _),
    do: {:ok, Google.Protobuf.to_datetime(value)}

  defp decode_message(%Google.Protobuf.Duration{} = value, _module, _),
    do: {:ok, Google.Protobuf.to_duration(value)}

  defp decode_message(%Google.Type.Date{year: year, month: month, day: day} = value, _, _) do
    case Date.new(year, month, day) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> invalid(value, "google.type.Date", "only full dates are supported")
    end
  end

  defp decode_message(%Google.Type.TimeOfDay{} = value, module, _) do
    microsecond = div(value.nanos, 1_000)
    precision = if module == Ash.Type.Time and microsecond == 0, do: 0, else: 6

    case Time.new(value.hours, value.minutes, value.seconds, {microsecond, precision}) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> invalid(value, "google.type.TimeOfDay", "invalid time of day")
    end
  end

  defp decode_message(%Google.Type.Decimal{value: string} = value, _, _) do
    case Decimal.parse(string) do
      {decimal, ""} -> {:ok, decimal}
      _ -> invalid(value, "google.type.Decimal", "invalid decimal")
    end
  end

  defp decode_message(%Google.Protobuf.Struct{} = value, _module, _), do: Json.from_struct(value)
  defp decode_message(%Google.Protobuf.Value{} = value, _module, _), do: Json.from_value(value)
  defp decode_message(%Google.Protobuf.ListValue{} = value, _module, _), do: Json.from_list(value)

  defp decode_message(%Google.Protobuf.FieldMask{paths: paths}, _module, _), do: {:ok, paths}
  defp decode_message(%Google.Protobuf.Empty{}, _module, _), do: {:ok, nil}

  defp decode_message(value, _module, full_name),
    do: invalid(value, full_name, "unexpected value")

  defp invalid(value, type, reason), do: {:error, {:invalid_value, value, type, reason}}

  defp tag_error({:error, {:invalid_value, _, _, _}} = error, _value, _type), do: error

  defp tag_error({:error, {:invalid_value, inner, reason}}, _value, type),
    do: {:error, {:invalid_value, inner, type, reason}}

  defp tag_error(result, _value, _type), do: result
end
