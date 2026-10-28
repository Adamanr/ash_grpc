defmodule AshGrpc.DataLayer.Mapping do
  @moduledoc """
  Binds foreign protobuf messages to Ash fields, for `AshGrpc.DataLayer` and `AshGrpc.Rpc`.

  A *binding* is a list of `{proto_field_name, ash_name, ash_type, constraints}` specs. Binding
  a message (see `bind/3`) sets the `source` of every bound field to
  `{:field, ash_name, ash_type, constraints}`, so `AshGrpc.Codec` converts values with the
  Ash types (timestamps to `DateTime`, enums to Ash atoms, …). Unbound fields are skipped.

  Enums of foreign messages carry no Ash values. When a bound field is an enum and its Ash type
  has a fixed set of atoms (`:atom` with `one_of`, `Ash.Type.Enum`), each enum value is matched
  to an atom by name — `TICKET_STATUS_OPEN` (the AshGrpc convention, see
  `AshGrpc.Type.Naming.enum_value_name/2`) or `OPEN` both match `:open`.
  """

  alias AshGrpc.DataLayer.Foreign
  alias AshGrpc.Proto.IR
  alias AshGrpc.Type.{Kind, Naming}

  @typedoc "`{proto_field_name, ash_name, ash_type, constraints}`"
  @type spec :: {String.t(), atom(), Ash.Type.t(), Keyword.t()}

  @doc "Binds `message` (part of `schema`) to the given specs. See the module docs."
  @spec bind(IR.Message.t(), IR.Schema.t(), [spec()]) :: {IR.Message.t(), IR.Schema.t()}
  def bind(%IR.Message{} = message, %IR.Schema{} = schema, specs) do
    by_name =
      Map.new(specs, fn {proto, name, type, constraints} -> {proto, {name, type, constraints}} end)

    fields =
      Enum.map(message.fields, fn field ->
        case Map.fetch(by_name, field.name) do
          {:ok, {name, type, constraints}} ->
            %{field | source: {:field, name, type, constraints || []}}

          :error ->
            %{field | source: {:skip, :unbound}}
        end
      end)

    schema =
      Enum.reduce(fields, schema, fn
        %IR.Field{type: {:enum, full_name}, source: {:field, _, type, constraints}}, schema ->
          case enum_values(type, constraints) do
            [] -> schema
            values -> annotate_enum(schema, full_name, values)
          end

        _field, schema ->
          schema
      end)

    {%{message | fields: fields}, schema}
  end

  @doc """
  Builds a struct of the protobuf `module` from `values` (a map or record keyed by Ash names)
  through the binding `specs`.
  """
  @spec encode(module(), map() | struct(), [spec()]) :: {:ok, struct()} | {:error, term()}
  def encode(module, values, specs) do
    with {:ok, message, schema} <- Foreign.message(module) do
      {message, schema} = bind(message, schema, specs)
      AshGrpc.Codec.encode_record(values, message, schema)
    end
  end

  @doc """
  Decodes a protobuf `struct` into a map keyed by Ash names through the binding `specs`.

  Options are passed to `AshGrpc.Codec.decode_message/4` (`:present`).
  """
  @spec decode(struct(), [spec()], Keyword.t()) :: {:ok, map()} | {:error, term()}
  def decode(%module{} = struct, specs, opts \\ []) do
    with {:ok, message, schema} <- Foreign.message(module) do
      {message, schema} = bind(message, schema, specs)
      AshGrpc.Codec.decode_message(struct, message, schema, opts)
    end
  end

  @doc """
  Decodes the value of `field` (an `IR.Field` of a message of `schema`) into a value of the
  Ash type `type` (`nil` for natural conversions: messages become maps keyed by field names).
  """
  @spec decode_value(term(), IR.Field.t(), IR.Schema.t(), Ash.Type.t() | nil, Keyword.t()) ::
          {:ok, term()} | {:error, term()}
  def decode_value(value, %IR.Field{} = field, schema, type, constraints) do
    {_message, schema} =
      bind(%IR.Message{fields: [field]}, schema, [{field.name, :value, type, constraints}])

    AshGrpc.Codec.decode(value, type, constraints || [], field.type, schema: schema)
  end

  @doc "Field names of the protobuf `module`, as strings."
  @spec field_names(module()) :: [String.t()]
  def field_names(module) do
    for {_tag, props} <- module.__message_props__().field_props, do: props.name
  end

  @doc "The struct key of the field named `name` of the protobuf `module`, or `nil`."
  @spec field_key(module(), String.t() | atom()) :: atom() | nil
  def field_key(module, name) do
    name = to_string(name)

    Enum.find_value(module.__message_props__().field_props, fn {_tag, props} ->
      if props.name == name, do: props.name_atom
    end)
  end

  @doc "The `IR.Field` named `name` of `message`, or `nil`."
  @spec field(IR.Message.t(), String.t() | atom()) :: IR.Field.t() | nil
  def field(%IR.Message{fields: fields}, name) do
    name = to_string(name)
    Enum.find(fields, &(&1.name == name))
  end

  @doc """
  Reads a (possibly nested) field path of a protobuf struct. A `nil` intermediate message
  yields `nil`.
  """
  @spec get_path(struct() | nil, [atom() | String.t()]) :: term()
  def get_path(value, []), do: value
  def get_path(nil, _path), do: nil

  def get_path(%module{} = struct, [name | rest]) do
    case field_key(module, name) do
      nil -> nil
      key -> struct |> Map.get(key) |> get_path(rest)
    end
  end

  # -- enums -------------------------------------------------------------------------------

  defp enum_values({:array, inner}, constraints),
    do: enum_values(inner, Keyword.get(constraints || [], :items, []))

  defp enum_values(type, constraints) do
    case Kind.classify(type, constraints || []) do
      {:enum, values, _module} -> values
      _ -> []
    end
  rescue
    _ -> []
  end

  defp annotate_enum(%IR.Schema{files: files} = schema, full_name, values) do
    update = fn enum ->
      if enum.full_name == full_name, do: annotate_values(enum, values), else: enum
    end

    %{
      schema
      | files:
          Enum.map(files, fn file ->
            %{
              file
              | enums: Enum.map(file.enums, update),
                messages: Enum.map(file.messages, &update_nested(&1, update))
            }
          end)
    }
  end

  defp update_nested(message, update) do
    %{
      message
      | nested_enums: Enum.map(message.nested_enums, update),
        nested_messages: Enum.map(message.nested_messages, &update_nested(&1, update))
    }
  end

  defp annotate_values(%IR.Enum{} = enum, values) do
    %{
      enum
      | values:
          Enum.map(enum.values, fn
            %IR.EnumValue{number: 0} = value ->
              value

            value ->
              case Enum.find(values, &matches?(value.name, enum.full_name, &1)) do
                nil -> value
                atom -> %{value | source: atom}
              end
          end)
    }
  end

  defp matches?(name, full_name, atom),
    do: name == Naming.enum_value_name(full_name, atom) or name == Naming.constant(atom)
end
