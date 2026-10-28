defmodule AshGrpc.Proto.Import.Options do
  @moduledoc """
  Converts descriptor option messages (`FileOptions`, `FieldOptions`, ...) into
  `AshGrpc.Proto.IR.Option` lists.

    * Standard options are emitted when they differ from the descriptor default
      (`protoc` does not keep track of "explicitly set to the default value").
    * Editions features become `features.<name>` options.
    * Custom options (extensions of `google.protobuf.*Options`, unknown fields
      when decoding) are decoded with the extension definitions found in the
      descriptor set and named `(full.extension.name)`. Message-typed values
      become maps with string keys, enum values become atoms, repeated options
      yield one `Option` per value. Options whose extension is not part of the
      descriptor set are dropped.
  """

  alias AshGrpc.Proto.Import.{Registry, Wire}
  alias AshGrpc.Proto.IR

  @extendees %{
    Google.Protobuf.FileOptions => "google.protobuf.FileOptions",
    Google.Protobuf.MessageOptions => "google.protobuf.MessageOptions",
    Google.Protobuf.FieldOptions => "google.protobuf.FieldOptions",
    Google.Protobuf.OneofOptions => "google.protobuf.OneofOptions",
    Google.Protobuf.EnumOptions => "google.protobuf.EnumOptions",
    Google.Protobuf.EnumValueOptions => "google.protobuf.EnumValueOptions",
    Google.Protobuf.ServiceOptions => "google.protobuf.ServiceOptions",
    Google.Protobuf.MethodOptions => "google.protobuf.MethodOptions",
    Google.Protobuf.FeatureSet => "google.protobuf.FeatureSet"
  }

  @always_skipped [:features, :uninterpreted_option]

  @scalars %{
    TYPE_DOUBLE: :double,
    TYPE_FLOAT: :float,
    TYPE_INT64: :int64,
    TYPE_UINT64: :uint64,
    TYPE_INT32: :int32,
    TYPE_FIXED64: :fixed64,
    TYPE_FIXED32: :fixed32,
    TYPE_BOOL: :bool,
    TYPE_STRING: :string,
    TYPE_BYTES: :bytes,
    TYPE_UINT32: :uint32,
    TYPE_SFIXED32: :sfixed32,
    TYPE_SFIXED64: :sfixed64,
    TYPE_SINT32: :sint32,
    TYPE_SINT64: :sint64
  }

  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc "Maps descriptor scalar type atoms (`:TYPE_INT32`) to IR scalars (`:int32`)."
  @spec scalar(atom()) :: IR.scalar() | nil
  def scalar(type), do: Map.get(@scalars, type)

  @doc """
  Converts an options struct. `skip` lists standard option keys that are
  represented elsewhere in the IR (e.g. `:deprecated` → `deprecated?`).
  """
  @spec convert(struct() | nil, [atom()], Registry.t()) :: [IR.Option.t()]
  def convert(nil, _skip, _registry), do: []

  def convert(%mod{} = options, skip, registry) do
    standard(options, skip) ++
      features(options, registry) ++ custom(options, Map.fetch!(@extendees, mod), "", registry)
  end

  @doc """
  Resolved value of an enum constant: the value name as an atom when it is a
  valid identifier declared in `enum_full_name`, otherwise the number.
  """
  @spec enum_constant(Registry.t(), String.t(), integer() | String.t()) :: atom() | integer()
  def enum_constant(registry, enum_full_name, number) when is_integer(number) do
    with %{value: values} <- registry.enums[enum_full_name],
         %{name: name} <- Enum.find(values, &(&1.number == number)) do
      identifier_atom(name)
    else
      _ -> number
    end
  end

  def enum_constant(_registry, _enum_full_name, name) when is_binary(name),
    do: identifier_atom(name)

  defp standard(%mod{} = options, skip) do
    defaults = struct(mod)
    props = mod.__message_props__()

    props.ordered_tags
    |> Enum.map(&props.field_props[&1].name_atom)
    |> Enum.reject(&(&1 in @always_skipped or &1 in skip))
    |> Enum.flat_map(fn key ->
      value = Map.fetch!(options, key)

      cond do
        value == Map.fetch!(defaults, key) -> []
        is_list(value) -> Enum.map(value, &option(key, &1))
        true -> [option(key, value)]
      end
    end)
  end

  defp option(key, value), do: %IR.Option{name: Atom.to_string(key), value: plain(value)}

  defp features(%{features: %Google.Protobuf.FeatureSet{} = features}, registry) do
    features
    |> standard([])
    |> Enum.map(&%{&1 | name: "features." <> &1.name})
    |> Kernel.++(custom(features, "google.protobuf.FeatureSet", "features.", registry))
  end

  defp features(_options, _registry), do: []

  defp custom(options, extendee, name_prefix, registry) do
    options
    |> Protobuf.get_unknown_fields()
    |> Enum.flat_map(fn {number, wire_type, raw} ->
      case registry.extensions[{extendee, number}] do
        {full_name, field} ->
          field
          |> decode_field(wire_type, raw, registry)
          |> Enum.map(&%IR.Option{name: "#{name_prefix}(#{full_name})", value: &1})

        nil ->
          []
      end
    end)
  end

  # Decodes one occurrence of a field into a list of values (packed fields yield several).
  defp decode_field(%{type: type} = field, wire_type, raw, registry)
       when type in [:TYPE_MESSAGE, :TYPE_GROUP] and wire_type in [2, 3] do
    full_name = Registry.strip(field.type_name)

    case Wire.parse(raw) do
      {:ok, fields} -> [decode_message(full_name, fields, registry)]
      :error -> []
    end
  end

  defp decode_field(%{type: :TYPE_ENUM} = field, wire_type, raw, registry) do
    raw
    |> unpack_if_needed(:int32, wire_type)
    |> Enum.map(fn value ->
      enum_constant(
        registry,
        Registry.strip(field.type_name),
        Protobuf.Wire.decode(:int32, value)
      )
    end)
  end

  defp decode_field(%{type: type}, wire_type, raw, _registry) do
    case scalar(type) do
      nil -> []
      scalar -> raw |> unpack_if_needed(scalar, wire_type) |> Enum.map(&decode_scalar(scalar, &1))
    end
  end

  defp decode_scalar(scalar, value) do
    Protobuf.Wire.decode(scalar, value)
  rescue
    Protobuf.DecodeError -> value
  end

  defp unpack_if_needed(raw, scalar, 2) when scalar not in [:string, :bytes] do
    case Wire.unpack(raw, Protobuf.Wire.wire_type(scalar)) do
      {:ok, values} -> values
      :error -> []
    end
  end

  defp unpack_if_needed(raw, _scalar, _wire_type), do: [raw]

  defp decode_message(full_name, fields, registry) do
    case registry.messages[full_name] do
      nil ->
        %{}

      descriptor ->
        by_number = Enum.group_by(fields, &elem(&1, 0))

        Enum.reduce(descriptor.field, %{}, fn field, acc ->
          put_field(acc, field, Map.get(by_number, field.number, []), registry)
        end)
    end
  end

  defp put_field(acc, field, occurrences, registry) do
    values =
      Enum.flat_map(occurrences, fn {_, wire_type, raw} ->
        decode_field(field, wire_type, raw, registry)
      end)

    cond do
      values == [] -> acc
      field.label == :LABEL_REPEATED -> Map.put(acc, field.name, values)
      # last one wins for singular fields, as in the protobuf spec
      true -> Map.put(acc, field.name, List.last(values))
    end
  end

  # Values of standard options are protobuf structs/atoms/scalars; nested
  # structs (e.g. `FieldOptions.FeatureSupport`) become plain maps.
  defp plain(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} ->
      value in [nil, []] or key |> Atom.to_string() |> String.starts_with?("__")
    end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), plain(value)} end)
  end

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  # Enum constants are atoms in the IR (printed as identifiers). They come from
  # local descriptor files, never from a remote peer, and are validated first.
  defp identifier_atom(name) do
    if Regex.match?(@identifier, name) do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      String.to_atom(name)
    else
      raise ArgumentError, "invalid protobuf identifier #{inspect(name)}"
    end
  end
end
