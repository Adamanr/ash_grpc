defmodule AshGrpc.Codec do
  @moduledoc """
  Converts between Ash values and the values stored in protobuf-elixir structs.

  The conversions mirror `AshGrpc.Type.Mapping`: given the Ash type, its
  constraints and the IR field type the value is (or was) mapped to,
  `encode/5` produces the protobuf field value and `decode/5` the value Ash
  casts. Types implementing `AshGrpc.Type.encode_proto/2` / `decode_proto/2`
  take over their own conversion.

  | Ash value | protobuf-elixir value |
  |---|---|
  | `DateTime` | `%Google.Protobuf.Timestamp{}` (or ISO-8601 string) |
  | `Duration` | `%Google.Protobuf.Duration{}` (or ISO-8601 string; months/years are rejected) |
  | `Date` / `Time` | `%Google.Type.Date{}` / `%Google.Type.TimeOfDay{}` |
  | `Decimal` | string (`:normal` notation) or `%Google.Type.Decimal{}` |
  | UUID | string or 16 raw bytes |
  | enum atom | enum value atom (`:USER_ROLE_ADMIN`); `*_UNSPECIFIED`/`0` decodes to `nil` |
  | untyped map, `:term` | `%Google.Protobuf.Struct{}` / `%Google.Protobuf.Value{}` |
  | typed map / embedded resource | the message struct (`encode_record/4`) |
  | `%Ash.Union{type: t, value: v}` | wrapper struct with `value: {t, encoded}` |
  | list | list, or wrapper structs (see `AshGrpc.Type.Mapping`) |
  | `nil` | `nil` (absent) |

  Wrapper messages, generated messages and enums are looked up in the
  `IR.Schema` given as the `:schema` option (and by `encode_record/4` /
  `decode_message/4`); their `module` must be set. Well-known and
  `google.type.*` messages need no schema. Enums can be converted without a
  schema when they follow the AshGrpc naming convention.

  ## Field sources

  `encode_record/4` and `decode_message/4` use each IR field's `source` to find
  the Ash name, type and constraints of the value:

    * `{kind, name, type, constraints}` – explicit (any `kind`, e.g.
      `:attribute`, `:argument`, `:calculation`, `:aggregate`, `:field`, `:member`)
    * `{kind, name}` with `kind` in `:attribute`, `:calculation`, `:aggregate`,
      `:relationship`, `:argument` – type looked up on the resource of the message
      (`{:resource, r}`, `{:embedded, r}`, `{:action_input, r, action}`,
      `{:action_output, r, action}` message sources)
    * an atom – the Ash name, type looked up like above when possible
    * `nil` – the proto field name (an existing atom) with natural conversions
      (used for imported messages)

  Fields whose source is `{:skip, _}` are ignored.
  """

  alias AshGrpc.Codec.{Json, Scalar}
  alias AshGrpc.Proto.IR
  alias AshGrpc.Type.{Kind, Known, Mapping, Naming}

  @typedoc "A value as stored in a protobuf-elixir struct field."
  @type proto_value :: term()

  @typedoc """
  Options:

    * `:schema` – `IR.Schema` used to resolve generated messages and enums
  """
  @type opts :: Keyword.t()

  @lookup_kinds [:attribute, :calculation, :aggregate, :relationship, :argument]

  @doc """
  Encodes a (cast) Ash value into a protobuf struct field value.

  `ash_type` may be `nil` when unknown (natural conversions are used).
  """
  @spec encode(term(), Ash.Type.t() | nil, Keyword.t(), IR.field_type(), opts()) ::
          {:ok, proto_value()} | {:error, term()}
  def encode(value, ash_type, constraints, field_type, opts \\ [])

  def encode(value, nil, _constraints, field_type, opts),
    do: value |> encode_natural(field_type, opts) |> normalize_error(field_type)

  def encode(value, ash_type, constraints, field_type, opts) do
    constraints = constraints || []

    case custom(ash_type, :encode_proto) do
      {:ok, module} ->
        if is_nil(value), do: {:ok, nil}, else: module.encode_proto(value, constraints)

      :error ->
        ash_type
        |> Kind.classify(constraints, skip_custom: Ash.Type.get_type(ash_type))
        |> encode_kind(value, field_type, opts)
    end
    |> normalize_error(field_type)
  end

  @doc """
  Decodes a protobuf struct field value into a value Ash can cast.

  `ash_type` may be `nil` when unknown (natural conversions are used).
  """
  @spec decode(proto_value(), Ash.Type.t() | nil, Keyword.t(), IR.field_type(), opts()) ::
          {:ok, term()} | {:error, term()}
  def decode(value, ash_type, constraints, field_type, opts \\ [])

  def decode(value, nil, _constraints, field_type, opts),
    do: value |> decode_natural(field_type, opts) |> normalize_error(field_type)

  def decode(value, ash_type, constraints, field_type, opts) do
    constraints = constraints || []

    case custom(ash_type, :decode_proto) do
      {:ok, module} ->
        if is_nil(value), do: {:ok, nil}, else: module.decode_proto(value, constraints)

      :error ->
        ash_type
        |> Kind.classify(constraints, skip_custom: Ash.Type.get_type(ash_type))
        |> decode_kind(value, field_type, opts)
    end
    |> normalize_error(field_type)
  end

  @doc """
  Builds the protobuf struct of `message` from a record (or map / keyword list).

  Values that are not loaded (`%Ash.NotLoaded{}`) or forbidden
  (`%Ash.ForbiddenField{}`) are left at their protobuf default (absent).
  """
  @spec encode_record(term(), IR.Message.t(), IR.Schema.t() | nil, opts()) ::
          {:ok, struct()} | {:error, term()}
  def encode_record(record, message, schema, opts \\ [])

  def encode_record(nil, _message, _schema, _opts), do: {:ok, nil}

  def encode_record(record, %IR.Message{} = message, schema, opts) do
    opts = Keyword.put(opts, :schema, schema)

    with {:ok, module} <- message_module(message),
         {:ok, fields} <-
           reduce_ok(message.fields, [], &encode_field(record, message, &1, &2, opts)) do
      {:ok, struct(module, fields)}
    end
  end

  defp encode_field(record, message, field, acc, opts) do
    with {:ok, {key, type, constraints}} <- field_spec(field, message),
         {:ok, value} <- fetch(record, key),
         {:ok, encoded} <-
           value |> encode(type, constraints, field.type, opts) |> within(field.name) do
      {:ok, put_field(acc, field, encoded)}
    else
      :skip -> {:ok, acc}
      error -> error
    end
  end

  @doc """
  Decodes a protobuf struct of `message` into an input map keyed by Ash names.

  Absent fields are skipped so that Ash defaults apply: `nil` optional scalars,
  `nil` messages, empty repeated/map fields and unset oneof members.
  Implicit-presence fields are always included (enum `*_UNSPECIFIED` → `nil`).

  Options:

    * `:present` – proto field names to include even when absent (decoded as
      `nil`/`[]`), e.g. the paths of an update mask.
  """
  @spec decode_message(struct() | nil, IR.Message.t(), IR.Schema.t() | nil, opts()) ::
          {:ok, %{atom() => term()}} | {:error, term()}
  def decode_message(struct, message, schema, opts \\ [])

  def decode_message(nil, _message, _schema, _opts), do: {:ok, nil}

  def decode_message(struct, %IR.Message{} = message, schema, opts) when is_struct(struct) do
    present = Keyword.get(opts, :present, [])
    opts = opts |> Keyword.delete(:present) |> Keyword.put(:schema, schema)

    reduce_ok(message.fields, %{}, &decode_field(struct, message, &1, &2, present, opts))
  end

  def decode_message(other, %IR.Message{} = message, _schema, _opts),
    do: {:error, {:invalid_value, other, message.full_name, "expected a message struct"}}

  defp decode_field(struct, message, field, acc, present, opts) do
    with {:ok, {key, type, constraints}} <- field_spec(field, message),
         {:ok, raw} <- read_field(struct, field, field.name in present),
         {:ok, value} <- raw |> decode(type, constraints, field.type, opts) |> within(field.name) do
      {:ok, Map.put(acc, key, value)}
    else
      :skip -> {:ok, acc}
      error -> error
    end
  end

  ## kinds — encode

  defp encode_kind(_kind, nil, _field_type, _opts), do: {:ok, nil}

  defp encode_kind({:array, inner, item_constraints, _}, value, field_type, opts) do
    with {:ok, list} <- to_list(value) do
      case list_wrapper(field_type, {:array, inner}, opts) do
        {:ok, message, values_field} ->
          wrap_list(list, message, inner, item_constraints, values_field.type, opts)

        :error ->
          encode_items(list, inner, item_constraints, field_type, opts)
      end
    end
  end

  defp encode_kind({:enum, values, module}, value, field_type, opts),
    do: encode_enum(value, values, module, field_type, opts)

  defp encode_kind({:resource, resource}, value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name) do
      Scalar.encode(value, resource, field_type)
    else
      with {:ok, message} <- lookup_message(full_name, opts) do
        encode_record(value, message, opts[:schema], opts)
      end
    end
  end

  defp encode_kind({:fields, base_type, fields}, value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name) do
      Scalar.encode(value, base_type, field_type)
    else
      with {:ok, message} <- lookup_message(full_name, opts),
           {:ok, record} <- fields_record(value, base_type, fields) do
        encode_record(record, message, opts[:schema], opts)
      end
    end
  end

  defp encode_kind({:union, _types}, value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name),
      do: Scalar.encode(value, Ash.Type.Union, field_type),
      else: encode_union(value, full_name, opts)
  end

  defp encode_kind({kind_name, _, _}, value, :string, _opts) when kind_name in [:fields],
    do: Json.encode_string(value)

  defp encode_kind({kind_name, _}, value, :string, _opts) when kind_name in [:union, :resource],
    do: Json.encode_string(value)

  defp encode_kind({:unsupported, type}, value, field_type, _opts),
    do: Scalar.encode(value, type, field_type)

  defp encode_kind({:basic, Ash.Type.Vector, _}, %Ash.Vector{} = value, field_type, opts),
    do: encode_kind({:basic, Ash.Type.Vector, []}, Ash.Vector.to_list(value), field_type, opts)

  defp encode_kind({:basic, Ash.Type.Vector, _}, value, field_type, _opts) when is_list(value),
    do: map_ok(value, &Scalar.encode(&1, Ash.Type.Float, field_type))

  defp encode_kind({:basic, module, _}, value, field_type, _opts),
    do: Scalar.encode(value, module, field_type)

  defp encode_kind({:custom, module, _}, value, field_type, _opts),
    do: Scalar.encode(value, module, field_type)

  defp encode_kind(kind, value, field_type, _opts),
    do: {:error, {:invalid_value, value, field_type, "cannot encode #{inspect(kind)}"}}

  defp wrap_list(list, message, inner, item_constraints, values_type, opts) do
    with {:ok, module} <- message_module(message),
         {:ok, values} <- encode_items(list, inner, item_constraints, values_type, opts) do
      {:ok, struct(module, values: values)}
    end
  end

  # a list wrapper message that wraps a whole list of this depth
  defp list_wrapper(field_type, list_type, opts) do
    case wrapper(field_type, opts) do
      {:list, %IR.Message{source: {_, wrapped, _}} = message, values_field} ->
        if depth(wrapped) == depth(list_type), do: {:ok, message, values_field}, else: :error

      _ ->
        :error
    end
  end

  defp encode_items(list, inner, item_constraints, field_type, opts) do
    encode_item =
      case wrapper(field_type, opts) do
        {:item, message, value_field} ->
          &encode_wrapped_item(&1, message, inner, item_constraints, value_field.type, opts)

        _ ->
          &encode_item(&1, inner, item_constraints, field_type, opts)
      end

    list
    |> Enum.with_index()
    |> map_ok(fn {item, index} -> item |> encode_item.() |> within(index) end)
  end

  defp encode_wrapped_item(item, message, inner, item_constraints, value_type, opts) do
    with {:ok, module} <- message_module(message),
         {:ok, encoded} <- encode(item, inner, item_constraints, value_type, opts) do
      {:ok, struct(module, value: encoded)}
    end
  end

  defp encode_item(nil, _inner, _item_constraints, field_type, _opts),
    do: {:error, {:invalid_value, nil, field_type, "nil items are not allowed"}}

  defp encode_item(item, inner, item_constraints, field_type, opts),
    do: encode(item, inner, item_constraints, field_type, opts)

  defp encode_enum(value, values, module, {:enum, full_name}, opts) do
    if value in values,
      do: enum_value(value, full_name, opts),
      else: {:error, {:invalid_value, value, full_name, "not a value of #{enum_label(module)}"}}
  end

  defp encode_enum(value, values, _module, field_type, _opts)
       when field_type in [:string, {:message, "google.protobuf.StringValue"}] do
    if value in values,
      do: Scalar.encode(to_string(value), Ash.Type.String, field_type),
      else: {:error, {:invalid_value, value, field_type, "not a value of the enum"}}
  end

  defp encode_enum(value, _values, _module, field_type, _opts),
    do: {:error, {:invalid_value, value, field_type, "cannot encode an enum value"}}

  defp enum_value(value, full_name, opts) do
    case lookup_enum(full_name, opts) do
      {:ok, enum} ->
        case Enum.find(enum.values, &(&1.source == value)) do
          nil -> {:error, {:invalid_value, value, full_name, "not a value of the enum"}}
          enum_value -> {:ok, enum_value_atom(enum_value)}
        end

      :error ->
        # values are known Ash values, so the derived names are bounded
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        {:ok, String.to_atom(Naming.enum_value_name(full_name, value))}
    end
  end

  defp encode_union(%Ash.Union{type: member, value: value}, full_name, opts) do
    with {:ok, message} <- lookup_message(full_name, opts),
         {:ok, module} <- message_module(message),
         {:ok, field, type, constraints} <- union_member(message, member),
         {:ok, encoded} <-
           value |> encode(type, constraints, field.type, opts) |> within(field.name) do
      {:ok, struct(module, [{oneof_key(field), {field_key(field), encoded}}])}
    end
  end

  defp encode_union(value, full_name, _opts),
    do: {:error, {:invalid_value, value, full_name, "expected %Ash.Union{}"}}

  defp union_member(message, member) do
    case Enum.find(message.fields, &match?({:member, ^member, _, _}, &1.source)) do
      %IR.Field{source: {:member, _, type, constraints}} = field ->
        {:ok, field, type, constraints}

      nil ->
        {:error, {:invalid_value, member, message.full_name, "unknown union member"}}
    end
  end

  ## kinds — decode

  defp decode_kind({:array, _, _, _}, nil, _field_type, _opts), do: {:ok, nil}

  defp decode_kind({:array, inner, item_constraints, _}, list, field_type, opts)
       when is_list(list),
       do: decode_items(list, inner, item_constraints, field_type, opts)

  defp decode_kind(
         {:array, inner, item_constraints, _},
         %{values: values} = value,
         field_type,
         opts
       ) do
    case list_wrapper(field_type, {:array, inner}, opts) do
      {:ok, _message, values_field} ->
        decode_items(values, inner, item_constraints, values_field.type, opts)

      :error ->
        {:error, {:invalid_value, value, field_type, "expected a list"}}
    end
  end

  defp decode_kind({:array, _, _, _}, value, field_type, _opts),
    do: {:error, {:invalid_value, value, field_type, "expected a list"}}

  defp decode_kind(_kind, nil, _field_type, _opts), do: {:ok, nil}

  defp decode_kind({:enum, values, module}, value, field_type, opts),
    do: decode_enum(value, values, module, field_type, opts)

  defp decode_kind({:resource, resource}, value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name) do
      Scalar.decode(value, resource, field_type)
    else
      with {:ok, message} <- lookup_message(full_name, opts) do
        decode_message(value, message, opts[:schema], opts)
      end
    end
  end

  defp decode_kind({:fields, base_type, fields}, value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name) do
      Scalar.decode(value, base_type, field_type)
    else
      with {:ok, message} <- lookup_message(full_name, opts),
           {:ok, map} <- decode_message(value, message, opts[:schema], opts) do
        {:ok, from_fields_map(map, base_type, fields)}
      end
    end
  end

  defp decode_kind({:union, _}, value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name),
      do: Scalar.decode(value, Ash.Type.Union, field_type),
      else: decode_union(value, full_name, opts)
  end

  defp decode_kind({kind_name, _, _}, value, :string, _opts) when kind_name in [:fields],
    do: Json.decode_string(value)

  defp decode_kind({kind_name, _}, value, :string, _opts) when kind_name in [:union, :resource],
    do: Json.decode_string(value)

  defp decode_kind({:unsupported, type}, value, field_type, _opts),
    do: Scalar.decode(value, type, field_type)

  defp decode_kind({:basic, Ash.Type.Vector, _}, value, field_type, _opts) when is_list(value),
    do: map_ok(value, &Scalar.decode(&1, Ash.Type.Float, field_type))

  defp decode_kind({:basic, module, _}, value, field_type, _opts),
    do: Scalar.decode(value, module, field_type)

  defp decode_kind({:custom, module, _}, value, field_type, _opts),
    do: Scalar.decode(value, module, field_type)

  defp decode_kind(kind, value, field_type, _opts),
    do: {:error, {:invalid_value, value, field_type, "cannot decode #{inspect(kind)}"}}

  defp decode_items(list, inner, item_constraints, field_type, opts) do
    item =
      case wrapper(field_type, opts) do
        {:item, _message, value_field} ->
          fn item ->
            decode(Map.get(item, :value), inner, item_constraints, value_field.type, opts)
          end

        _ ->
          fn item -> decode(item, inner, item_constraints, field_type, opts) end
      end

    list
    |> Enum.with_index()
    |> map_ok(fn {value, index} -> value |> item.() |> within(index) end)
  end

  defp decode_enum(value, values, module, {:enum, full_name}, opts) do
    case lookup_enum(full_name, opts) do
      {:ok, enum} ->
        case find_enum_value(enum, value) do
          nil -> {:error, {:invalid_value, value, full_name, "unknown enum value"}}
          %IR.EnumValue{number: 0} -> {:ok, nil}
          %IR.EnumValue{source: source} -> {:ok, source}
        end

      :error ->
        decode_conventional_enum(value, values, module, full_name)
    end
  end

  defp decode_enum(value, values, _module, field_type, _opts)
       when field_type in [:string, {:message, "google.protobuf.StringValue"}] do
    with {:ok, string} <- Scalar.decode(value, Ash.Type.String, field_type) do
      case string do
        nil -> {:ok, nil}
        "" -> {:ok, nil}
        string -> enum_from_string(string, values, field_type)
      end
    end
  end

  defp decode_enum(value, _values, _module, field_type, _opts),
    do: {:error, {:invalid_value, value, field_type, "cannot decode an enum value"}}

  # protobuf-elixir decodes known values to atoms and unknown ones to integers
  defp find_enum_value(enum, value) when is_integer(value),
    do: Enum.find(enum.values, &(&1.number == value))

  defp find_enum_value(enum, value) when is_atom(value),
    do: Enum.find(enum.values, &(&1.name == Atom.to_string(value)))

  defp find_enum_value(_enum, _value), do: nil

  defp decode_conventional_enum(0, _values, _module, _full_name), do: {:ok, nil}

  defp decode_conventional_enum(value, values, _module, full_name) when is_atom(value) do
    name = Atom.to_string(value)

    if name == Naming.unspecified_name(full_name) do
      {:ok, nil}
    else
      case Enum.find(values, &(Naming.enum_value_name(full_name, &1) == name)) do
        nil -> {:error, {:invalid_value, value, full_name, "unknown enum value"}}
        found -> {:ok, found}
      end
    end
  end

  defp decode_conventional_enum(value, _values, _module, full_name),
    do: {:error, {:invalid_value, value, full_name, "unknown enum value"}}

  defp enum_from_string(string, values, field_type) do
    case Enum.find(values, &(to_string(&1) == string)) do
      nil -> {:error, {:invalid_value, string, field_type, "unknown enum value"}}
      found -> {:ok, found}
    end
  end

  defp decode_union(value, full_name, opts) do
    with {:ok, message} <- lookup_message(full_name, opts) do
      decode_union_value(Map.get(value, :value), message, opts)
    end
  end

  defp decode_union_value(nil, _message, _opts), do: {:ok, nil}

  defp decode_union_value({tag, raw}, message, opts) do
    case Enum.find(message.fields, &(field_key(&1) == tag)) do
      %IR.Field{source: {:member, member, type, constraints}} = field ->
        with {:ok, decoded} <-
               raw |> decode(type, constraints, field.type, opts) |> within(field.name) do
          {:ok, %Ash.Union{type: member, value: decoded}}
        end

      _ ->
        {:error, {:invalid_value, tag, message.full_name, "unknown union member"}}
    end
  end

  defp decode_union_value(other, message, _opts),
    do: {:error, {:invalid_value, other, message.full_name, "invalid oneof value"}}

  ## natural conversions (unknown Ash type)

  defp encode_natural(nil, _field_type, _opts), do: {:ok, nil}

  defp encode_natural(value, {:enum, full_name}, opts) when is_atom(value) do
    case lookup_enum(full_name, opts) do
      {:ok, enum} ->
        case Enum.find(enum.values, &(&1.source == value or &1.name == Atom.to_string(value))) do
          nil -> {:ok, value}
          enum_value -> {:ok, enum_value_atom(enum_value)}
        end

      :error ->
        {:ok, value}
    end
  end

  defp encode_natural(value, {:enum, _}, _opts) when is_integer(value), do: {:ok, value}

  defp encode_natural(value, {:map, key_type, value_type}, opts) when is_map(value) do
    value
    |> map_ok(fn {key, item} ->
      with {:ok, key} <- encode_natural(key, key_type, opts),
           {:ok, item} <- encode_natural(item, value_type, opts) do
        {:ok, {key, item}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp encode_natural(value, field_type, opts) when is_list(value) and field_type != :string do
    if Keyword.keyword?(value) and value != [] and match?({:message, _}, field_type) do
      encode_natural_message(value, field_type, opts)
    else
      map_ok(value, &encode_natural(&1, field_type, opts))
    end
  end

  defp encode_natural(value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name),
      do: Scalar.encode(value, nil, field_type),
      else: encode_natural_message(value, field_type, opts)
  end

  defp encode_natural(value, field_type, _opts), do: Scalar.encode(value, nil, field_type)

  defp encode_natural_message(%_{__protobuf__: _} = value, _field_type, _opts), do: {:ok, value}

  defp encode_natural_message(value, {:message, full_name}, opts) do
    with {:ok, message} <- lookup_message(full_name, opts) do
      encode_record(value, message, opts[:schema], opts)
    end
  end

  defp decode_natural(nil, _field_type, _opts), do: {:ok, nil}

  defp decode_natural(value, {:enum, full_name}, opts) do
    case lookup_enum(full_name, opts) do
      {:ok, enum} -> natural_enum_value(find_enum_value(enum, value), value, full_name)
      :error -> {:ok, value}
    end
  end

  defp decode_natural(value, {:map, _key_type, value_type}, opts) when is_map(value) do
    value
    |> map_ok(fn {key, item} ->
      with {:ok, item} <- decode_natural(item, value_type, opts), do: {:ok, {key, item}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp decode_natural(value, field_type, opts) when is_list(value),
    do: map_ok(value, &decode_natural(&1, field_type, opts))

  defp decode_natural(value, {:message, full_name} = field_type, opts) do
    if Known.known?(full_name) do
      Scalar.decode(value, nil, field_type)
    else
      with {:ok, message} <- lookup_message(full_name, opts) do
        decode_message(value, message, opts[:schema], opts)
      end
    end
  end

  defp decode_natural(value, field_type, _opts), do: Scalar.decode(value, nil, field_type)

  defp natural_enum_value(%IR.EnumValue{number: 0}, _value, _full_name), do: {:ok, nil}

  defp natural_enum_value(%IR.EnumValue{source: source}, _value, _full_name)
       when not is_nil(source),
       do: {:ok, source}

  defp natural_enum_value(%IR.EnumValue{}, value, _full_name), do: {:ok, value}

  defp natural_enum_value(nil, value, full_name),
    do: {:error, {:invalid_value, value, full_name, "unknown enum value"}}

  ## records and fields

  defp field_spec(%IR.Field{source: {:skip, _}}, _message), do: :skip

  defp field_spec(%IR.Field{source: {_kind, name, type, constraints}}, _message)
       when is_atom(name),
       do: {:ok, {name, type, constraints || []}}

  defp field_spec(%IR.Field{source: {kind, name}}, message) when kind in @lookup_kinds,
    do: {:ok, lookup_field_type(kind, name, message)}

  defp field_spec(%IR.Field{source: name}, message) when is_atom(name) and not is_nil(name),
    do: {:ok, lookup_field_type(nil, name, message)}

  defp field_spec(%IR.Field{source: nil, name: name}, _message) do
    {:ok, {String.to_existing_atom(name), nil, []}}
  rescue
    ArgumentError -> :skip
  end

  defp field_spec(%IR.Field{source: source, name: name}, _message),
    do: {:error, {:unsupported_field_source, name, source}}

  defp lookup_field_type(kind, name, %IR.Message{source: source}) do
    case source_resource(source) do
      {resource, action} ->
        case resource_field(kind, resource, action, name) do
          nil -> {name, nil, []}
          {type, constraints} -> {name, type, constraints}
        end

      nil ->
        {name, nil, []}
    end
  end

  defp source_resource({kind, resource}) when kind in [:resource, :embedded], do: {resource, nil}

  defp source_resource({kind, resource, action}) when kind in [:action_input, :action_output],
    do: {resource, action}

  defp source_resource(_), do: nil

  defp resource_field(:relationship, resource, _action, name) do
    case Ash.Resource.Info.relationship(resource, name) do
      %{cardinality: :many, destination: destination} -> {{:array, destination}, []}
      %{destination: destination} -> {destination, []}
      nil -> nil
    end
  end

  defp resource_field(kind, resource, action, name) when kind in [:argument, nil] do
    with nil <- action_argument(resource, action, name) do
      if kind == nil, do: resource_field(:attribute, resource, action, name)
    end
  end

  defp resource_field(_kind, resource, _action, name) do
    case Ash.Resource.Info.field(resource, name) do
      %{type: type} = field -> {type, Map.get(field, :constraints) || []}
      nil -> resource_field(:relationship, resource, nil, name)
    end
  end

  defp action_argument(_resource, nil, _name), do: nil

  defp action_argument(resource, action, name) do
    with %{arguments: arguments} <- Ash.Resource.Info.action(resource, action),
         %{type: type, constraints: constraints} <- Enum.find(arguments, &(&1.name == name)) do
      {type, constraints}
    else
      _ -> nil
    end
  end

  defp fetch(record, key) do
    value =
      cond do
        is_map(record) -> Map.get(record, key)
        Keyword.keyword?(record) -> Keyword.get(record, key)
        true -> nil
      end

    case value do
      %Ash.NotLoaded{} -> :skip
      %Ash.ForbiddenField{} -> :skip
      value -> {:ok, value}
    end
  end

  defp put_field(acc, _field, nil), do: acc

  defp put_field(acc, %IR.Field{oneof: oneof} = field, value) when is_binary(oneof),
    do: [{oneof_key(field), {field_key(field), value}} | acc]

  defp put_field(acc, field, value), do: [{field_key(field), value} | acc]

  defp read_field(struct, %IR.Field{oneof: oneof} = field, force?) when is_binary(oneof) do
    tag = field_key(field)

    case Map.get(struct, oneof_key(field)) do
      {^tag, value} -> {:ok, value}
      _ when force? -> {:ok, nil}
      _ -> :skip
    end
  end

  defp read_field(struct, field, force?) do
    value = Map.get(struct, field_key(field))
    if force? or present?(value, field), do: {:ok, value}, else: :skip
  end

  defp present?(value, %IR.Field{label: :repeated}), do: value not in [[], %{}]
  defp present?(value, %IR.Field{type: {:map, _, _}}), do: value != %{}
  defp present?(value, %IR.Field{type: {:message, _}}), do: not is_nil(value)
  # implicit presence: the default value is a value
  defp present?(_value, %IR.Field{label: label}) when label in [nil, :required], do: true
  defp present?(value, _field), do: not is_nil(value)

  # IR names come from compiled schemas (the struct modules define the atoms)
  defp field_key(%IR.Field{name: name}), do: String.to_existing_atom(name)
  defp oneof_key(%IR.Field{oneof: oneof}), do: String.to_existing_atom(oneof)

  defp fields_record(value, Ash.Type.Tuple, fields) when is_tuple(value) do
    keys = Keyword.keys(fields)

    if tuple_size(value) == length(keys),
      do: {:ok, Enum.zip(keys, Tuple.to_list(value)) |> Map.new()},
      else: {:error, {:invalid_value, value, Ash.Type.Tuple, "wrong tuple size"}}
  end

  defp fields_record(value, _base_type, _fields) when is_map(value), do: {:ok, value}

  defp fields_record(value, _base_type, _fields) when is_list(value) do
    if Keyword.keyword?(value),
      do: {:ok, value},
      else: {:error, {:invalid_value, value, :map, "expected a map or keyword list"}}
  end

  defp fields_record(value, base_type, _fields),
    do: {:error, {:invalid_value, value, base_type, "expected a map"}}

  defp from_fields_map(map, Ash.Type.Tuple, fields),
    do: fields |> Keyword.keys() |> Enum.map(&Map.get(map, &1)) |> List.to_tuple()

  defp from_fields_map(map, Ash.Type.Keyword, fields) do
    fields
    |> Keyword.keys()
    |> Enum.filter(&Map.has_key?(map, &1))
    |> Enum.map(&{&1, Map.fetch!(map, &1)})
  end

  defp from_fields_map(map, _base_type, _fields), do: map

  ## schema helpers

  defp wrapper({:message, full_name}, opts) do
    with false <- Known.known?(full_name),
         {:ok, %IR.Message{source: source, fields: [field]} = message} <-
           lookup_message(full_name, opts) do
      case source do
        {:list_wrapper, _, _} -> {:list, message, field}
        {:item_wrapper, _, _} -> {:item, message, field}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp wrapper(_field_type, _opts), do: nil

  defp lookup_message(full_name, opts) do
    case opts[:schema] && IR.Schema.lookup(opts[:schema], full_name) do
      {:ok, %IR.Message{} = message} -> {:ok, message}
      _ -> {:error, {:unknown_message, full_name}}
    end
  end

  defp lookup_enum(full_name, opts) do
    case opts[:schema] && IR.Schema.lookup(opts[:schema], full_name) do
      {:ok, %IR.Enum{} = enum} -> {:ok, enum}
      _ -> :error
    end
  end

  defp message_module(%IR.Message{module: module}) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp message_module(%IR.Message{full_name: full_name}) do
    case Known.module(full_name) do
      nil -> {:error, {:no_module, full_name}}
      module -> {:ok, module}
    end
  end

  defp enum_value_atom(%IR.EnumValue{name: name, number: number}) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> number
  end

  defp enum_label(nil), do: "the enum"
  defp enum_label(module), do: inspect(module)

  defp custom(nil, _callback), do: :error

  defp custom({:array, _}, _callback), do: :error

  defp custom(type, callback) do
    type = Ash.Type.get_type(type)

    if is_atom(type) and Kind.custom?(type) and function_exported?(type, callback, 2),
      do: {:ok, type},
      else: :error
  end

  defp depth(type), do: Mapping.array_depth(type)

  defp to_list(value) when is_list(value), do: {:ok, value}
  defp to_list(%MapSet{} = value), do: {:ok, MapSet.to_list(value)}
  defp to_list(value), do: {:error, {:invalid_value, value, :list, "expected a list"}}

  defp normalize_error({:error, {:invalid_value, value, reason}}, field_type),
    do: {:error, {:invalid_value, value, field_type, reason}}

  defp normalize_error(result, _field_type), do: result

  defp within({:error, error}, segment), do: {:error, at(error, segment)}
  defp within(result, _segment), do: result

  # errors carry the path of the offending value: {:invalid_value, value, type, reason, path}
  defp at({:invalid_value, value, type, reason}, segment),
    do: {:invalid_value, value, type, reason, [segment]}

  defp at({:invalid_value, value, type, reason, path}, segment),
    do: {:invalid_value, value, type, reason, [segment | path]}

  defp at(error, _segment), do: error

  defp reduce_ok(enumerable, acc, fun) do
    Enum.reduce_while(enumerable, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

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
