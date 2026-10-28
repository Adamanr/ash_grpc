defmodule AshGrpc.Proto.Import.Mapper do
  @moduledoc """
  Maps one `Google.Protobuf.FileDescriptorProto` to an `AshGrpc.Proto.IR.File`.

  Use `AshGrpc.Proto.Import.from_descriptor_set/2` instead of calling this
  module directly; it builds the `AshGrpc.Proto.Import.Registry` this module
  needs and validates the result.
  """

  alias AshGrpc.Proto.Import.{Comments, Naming, Options, Registry}
  alias AshGrpc.Proto.IR

  # descriptor.proto field numbers used in source_code_info paths
  @file_message 4
  @file_enum 5
  @file_service 6
  @file_package 2
  @file_syntax 12
  @message_field 2
  @message_nested 3
  @message_enum 4
  @message_oneof 8
  @enum_value 2
  @service_method 2

  @message_max 536_870_911
  @enum_max 2_147_483_647

  defmodule Error do
    @moduledoc "Raised for descriptors that cannot be represented in the IR."
    defexception [:message]
  end

  @doc "Maps a file descriptor. Raises `Error` for unsupported constructs."
  @spec file(Google.Protobuf.FileDescriptorProto.t(), Registry.t(), Keyword.t()) :: IR.File.t()
  def file(%Google.Protobuf.FileDescriptorProto{} = file, %Registry{} = registry, opts) do
    syntax = syntax(file)

    ctx = %{
      registry: registry,
      opts: opts,
      package: blank_to_nil(file.package),
      path: file.name,
      syntax: syntax,
      comments: Comments.index(file),
      source: {:external, file.name},
      features: features_chain([], file.options)
    }

    %IR.File{
      path: file.name,
      package: ctx.package,
      syntax: syntax,
      doc:
        Comments.get(ctx.comments, [@file_package]) ||
          Comments.get(ctx.comments, [@file_syntax]),
      source: ctx.source,
      imports: file.dependency,
      public_imports: Enum.map(file.public_dependency, &Enum.at(file.dependency, &1)),
      options: Options.convert(file.options, [], registry),
      messages:
        file.message_type
        |> Enum.with_index()
        |> Enum.reject(fn {message, _} -> map_entry?(message) end)
        |> Enum.map(fn {message, index} ->
          message(message, [@file_message, index], [], ctx)
        end),
      enums:
        file.enum_type
        |> Enum.with_index()
        |> Enum.map(fn {enum, index} -> enum(enum, [@file_enum, index], [], ctx) end),
      services:
        file.service
        |> Enum.with_index()
        |> Enum.map(fn {service, index} -> service(service, [@file_service, index], ctx) end)
    }
  end

  defp syntax(%{syntax: "proto3"}), do: :proto3
  defp syntax(%{syntax: "editions", edition: edition}), do: {:edition, edition_name(edition)}
  defp syntax(_file), do: :proto2

  defp edition_name(edition) when is_atom(edition) and not is_nil(edition),
    do: edition |> Atom.to_string() |> String.replace_prefix("EDITION_", "")

  defp edition_name(edition), do: to_string(edition)

  ## messages

  defp message(message, path, scope, ctx) do
    names = scope ++ [message.name]
    full_name = IR.full_name(ctx.package, Enum.join(names, "."))
    ctx = %{ctx | features: features_chain(ctx.features, message.options)}
    synthetic = synthetic_oneofs(message)

    %IR.Message{
      name: message.name,
      full_name: full_name,
      module: Naming.module(ctx.package, names, ctx.opts),
      doc: Comments.get(ctx.comments, path),
      source: ctx.source,
      fields:
        message.field
        |> Enum.with_index()
        |> Enum.map(fn {field, index} ->
          field(field, path ++ [@message_field, index], full_name, message, synthetic, ctx)
        end),
      oneofs:
        message.oneof_decl
        |> Enum.with_index()
        |> Enum.reject(fn {_, index} -> index in synthetic end)
        |> Enum.map(fn {oneof, index} ->
          %IR.Oneof{
            name: oneof.name,
            doc: Comments.get(ctx.comments, path ++ [@message_oneof, index]),
            options: Options.convert(oneof.options, [], ctx.registry)
          }
        end),
      nested_messages:
        message.nested_type
        |> Enum.with_index()
        |> Enum.reject(fn {nested, _} -> map_entry?(nested) end)
        |> Enum.map(fn {nested, index} ->
          message(nested, path ++ [@message_nested, index], names, ctx)
        end),
      nested_enums:
        message.enum_type
        |> Enum.with_index()
        |> Enum.map(fn {enum, index} ->
          enum(enum, path ++ [@message_enum, index], names, ctx)
        end),
      reserved_numbers:
        Enum.map(message.reserved_range, &reserved_range(&1.start, &1.end - 1, @message_max)),
      reserved_names: message.reserved_name,
      options: Options.convert(message.options, [:map_entry], ctx.registry)
    }
  end

  defp map_entry?(%{options: %{map_entry: true}}), do: true
  defp map_entry?(_message), do: false

  # A oneof is synthetic when it only wraps a proto3 `optional` field.
  defp synthetic_oneofs(message) do
    message.field
    |> Enum.filter(&(&1.proto3_optional == true))
    |> Enum.map(& &1.oneof_index)
    |> MapSet.new()
  end

  ## fields

  defp field(field, path, message_full_name, message, synthetic, ctx) do
    if field.type == :TYPE_GROUP do
      raise Error,
            "#{message_full_name}.#{field.name}: proto2 groups are not supported (use a nested message)"
    end

    features = features_chain(ctx.features, field.options)

    if field.type == :TYPE_MESSAGE and delimited?(features) do
      raise Error,
            "#{message_full_name}.#{field.name}: DELIMITED message encoding is not supported"
    end

    type = field_type(field, ctx)
    oneof = oneof_name(field, message, synthetic)

    %IR.Field{
      name: field.name,
      number: field.number,
      type: type,
      label: label(field, type, oneof, features, ctx),
      oneof: oneof,
      json_name: json_name(field),
      default: default(field, ctx),
      doc: Comments.get(ctx.comments, path),
      source: ctx.source,
      deprecated?: deprecated?(field.options),
      options: Options.convert(field.options, [:deprecated], ctx.registry)
    }
  end

  defp field_type(%{type: :TYPE_MESSAGE, type_name: type_name}, ctx) do
    full_name = Registry.strip(type_name)

    if Registry.map_entry?(ctx.registry, full_name) do
      entry = ctx.registry.messages[full_name]
      key = Enum.find(entry.field, &(&1.number == 1))
      value = Enum.find(entry.field, &(&1.number == 2))
      {:map, Options.scalar(key.type), field_type(value, ctx)}
    else
      {:message, full_name}
    end
  end

  defp field_type(%{type: :TYPE_ENUM, type_name: type_name}, _ctx),
    do: {:enum, Registry.strip(type_name)}

  defp field_type(%{type: type}, _ctx), do: Options.scalar(type)

  defp oneof_name(%{oneof_index: nil}, _message, _synthetic), do: nil

  defp oneof_name(%{oneof_index: index}, message, synthetic) do
    if index in synthetic, do: nil, else: Enum.at(message.oneof_decl, index).name
  end

  defp label(%{label: :LABEL_REPEATED}, {:map, _, _}, _oneof, _features, _ctx), do: nil
  defp label(%{label: :LABEL_REPEATED}, _type, _oneof, _features, _ctx), do: :repeated
  defp label(%{label: :LABEL_REQUIRED}, _type, _oneof, _features, _ctx), do: :required
  defp label(_field, _type, oneof, _features, _ctx) when is_binary(oneof), do: nil
  defp label(_field, _type, _oneof, _features, %{syntax: :proto2}), do: :optional

  defp label(field, _type, _oneof, _features, %{syntax: :proto3}),
    do: if(field.proto3_optional, do: :optional, else: nil)

  defp label(_field, {:message, _}, _oneof, features, _ctx) do
    if Keyword.get(features, :field_presence) == :LEGACY_REQUIRED, do: :required, else: nil
  end

  defp label(_field, _type, _oneof, features, _ctx) do
    case Keyword.get(features, :field_presence, :EXPLICIT) do
      :IMPLICIT -> nil
      :LEGACY_REQUIRED -> :required
      _explicit -> :optional
    end
  end

  defp json_name(%{json_name: nil}), do: nil

  defp json_name(%{json_name: json_name, name: name}) do
    if json_name == Naming.default_json_name(name), do: nil, else: json_name
  end

  defp deprecated?(%{deprecated: true}), do: true
  defp deprecated?(_options), do: false

  ## defaults

  defp default(%{default_value: nil}, _ctx), do: nil

  defp default(%{default_value: value, type: :TYPE_ENUM, type_name: type_name}, ctx),
    do: Options.enum_constant(ctx.registry, Registry.strip(type_name), value)

  defp default(%{default_value: value, type: type}, _ctx) do
    case Options.scalar(type) do
      :string -> value
      :bytes -> unescape_bytes(value)
      :bool -> value == "true"
      float when float in [:double, :float] -> parse_float(value)
      _integer -> String.to_integer(value)
    end
  end

  defp parse_float("inf"), do: :infinity
  defp parse_float("-inf"), do: :negative_infinity
  defp parse_float("nan"), do: :nan

  defp parse_float(value) do
    {float, ""} = Float.parse(value)
    float
  end

  # protoc C-escapes bytes defaults (`CEscape`): \n \r \t \" \' \\, octal \ooo, hex \xHH.
  defp unescape_bytes(value), do: unescape_bytes(value, [])

  defp unescape_bytes(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp unescape_bytes(<<"\\", rest::binary>>, acc) do
    case rest do
      <<"n", rest::binary>> ->
        unescape_bytes(rest, ["\n" | acc])

      <<"r", rest::binary>> ->
        unescape_bytes(rest, ["\r" | acc])

      <<"t", rest::binary>> ->
        unescape_bytes(rest, ["\t" | acc])

      <<"x", rest::binary>> ->
        {digits, rest} = take_digits(rest, ~c"0123456789abcdefABCDEF", 2)
        unescape_bytes(rest, [String.to_integer(digits, 16) | acc])

      <<d, _::binary>> when d in ?0..?7 ->
        {digits, rest} = take_digits(rest, ~c"01234567", 3)
        unescape_bytes(rest, [rem(String.to_integer(digits, 8), 256) | acc])

      <<char, rest::binary>> ->
        unescape_bytes(rest, [char | acc])
    end
  end

  defp unescape_bytes(<<char, rest::binary>>, acc), do: unescape_bytes(rest, [char | acc])

  defp take_digits(binary, allowed, max), do: take_digits(binary, allowed, max, "")

  defp take_digits(<<d, rest::binary>>, allowed, max, acc) when byte_size(acc) < max do
    if d in allowed,
      do: take_digits(rest, allowed, max, acc <> <<d>>),
      else: {acc, <<d, rest::binary>>}
  end

  defp take_digits(rest, _allowed, _max, acc), do: {acc, rest}

  ## enums

  defp enum(enum, path, scope, ctx) do
    names = scope ++ [enum.name]

    %IR.Enum{
      name: enum.name,
      full_name: IR.full_name(ctx.package, Enum.join(names, ".")),
      module: Naming.module(ctx.package, names, ctx.opts),
      doc: Comments.get(ctx.comments, path),
      source: ctx.source,
      values:
        enum.value
        |> Enum.with_index()
        |> Enum.map(fn {value, index} ->
          %IR.EnumValue{
            name: value.name,
            number: value.number,
            doc: Comments.get(ctx.comments, path ++ [@enum_value, index]),
            deprecated?: deprecated?(value.options),
            options: Options.convert(value.options, [:deprecated], ctx.registry)
          }
        end),
      # enum reserved ranges are inclusive in descriptors (unlike message ones)
      reserved_numbers:
        Enum.map(enum.reserved_range, &reserved_range(&1.start, &1.end, @enum_max)),
      reserved_names: enum.reserved_name,
      allow_alias?: match?(%{allow_alias: true}, enum.options),
      options: Options.convert(enum.options, [:allow_alias], ctx.registry)
    }
  end

  defp reserved_range(start, max, max), do: {start, :max}
  defp reserved_range(start, start, _max), do: start
  defp reserved_range(start, last, _max), do: {start, last}

  ## services

  defp service(service, path, ctx) do
    %IR.Service{
      name: service.name,
      full_name: IR.full_name(ctx.package, service.name),
      module: Naming.service_module(ctx.package, service.name, ctx.opts),
      doc: Comments.get(ctx.comments, path),
      source: ctx.source,
      options: Options.convert(service.options, [], ctx.registry),
      rpcs:
        service.method
        |> Enum.with_index()
        |> Enum.map(fn {method, index} ->
          %IR.Rpc{
            name: method.name,
            input: Registry.strip(method.input_type),
            output: Registry.strip(method.output_type),
            doc: Comments.get(ctx.comments, path ++ [@service_method, index]),
            source: ctx.source,
            client_streaming?: method.client_streaming == true,
            server_streaming?: method.server_streaming == true,
            idempotency_level: idempotency_level(method.options),
            deprecated?: deprecated?(method.options),
            options:
              Options.convert(method.options, [:deprecated, :idempotency_level], ctx.registry)
          }
        end)
    }
  end

  defp idempotency_level(%{idempotency_level: :NO_SIDE_EFFECTS}), do: :no_side_effects
  defp idempotency_level(%{idempotency_level: :IDEMPOTENT}), do: :idempotent
  defp idempotency_level(_options), do: nil

  ## editions features (resolved innermost-wins)

  defp features_chain(parent, %{features: %Google.Protobuf.FeatureSet{} = features}) do
    features
    |> Map.take([:field_presence, :message_encoding])
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Enum.reduce(parent, fn {key, value}, acc -> Keyword.put(acc, key, value) end)
  end

  defp features_chain(parent, _options), do: parent

  defp delimited?(features), do: Keyword.get(features, :message_encoding) == :DELIMITED

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
