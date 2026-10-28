defmodule AshGrpc.Proto.Compiler do
  @moduledoc """
  Turns an `AshGrpc.Proto.IR.Schema` into Elixir modules compatible with the
  `protobuf` and `grpc` libraries (the same shape `protoc-gen-elixir` emits
  with `plugins=grpc,gen_descriptors=true`), so no `protoc` run is needed.

  Generated modules:

    * every `IR.Enum` → `use Protobuf, enum: true, ...` with one `field` per value
    * every `IR.Message` → `use Protobuf, syntax: ..., full_name: ...` with
      `oneof`/`field` declarations (`json_name`, `proto3_optional`, `oneof`,
      `enum`, `map`, `default`, `packed`, `deprecated` options as protoc-gen-elixir
      writes them)
    * every map field → a `<Message>.<Field>Entry` module (`map: true`)
    * every `IR.Service` → `use GRPC.Service, name: ...` with `rpc` declarations
      (`stream(...)` for streaming sides) and a stub module with `use GRPC.Stub`
      (see `stub_module/1`)
    * every message/enum/service module defines `descriptor/0` returning its
      `Google.Protobuf.DescriptorProto` / `EnumDescriptorProto` /
      `ServiceDescriptorProto`, built from the IR exactly like protoc would build
      it from the rendered `.proto` (see `file_descriptor/2`). This is what
      `grpc_reflection` reads.

  ## Module names

  Modules come from the `:module` field of the IR nodes. When it is `nil` the
  protoc-gen-elixir convention is used: every segment of the full name is
  camelized (`acme.shop.v1.User` → `Acme.Shop.V1.User`). Referenced types that
  are not part of the schema are resolved through `AshGrpc.Proto.WellKnown`,
  then the `:modules` option, then the same convention (which matches
  `googleapis`, e.g. `google.type.Date` → `Google.Type.Date`).

  `IR.Service.module` is the `GRPC.Service` module itself. Its stub is
  `stub_module/1`: for protoc-style names ending in `.Service`
  (`Acme.UserService.Service`) the sibling `Acme.UserService.Stub`, otherwise
  `<module>.Stub`.

  ## Limitations

    * custom options (`(my.ext).opt`) are rendered into `.proto` files but are not
      encoded into descriptors (their extension definitions are not part of the IR);
      standard options are
    * proto2 extensions/groups are not part of the IR; editions cannot be compiled
      (`ArgumentError`)

  ## Options

    * `:modules` – `%{full_name => module}` for referenced types outside the schema
    * `:docs` – emit `@moduledoc` from IR docs (default `true`); otherwise `@moduledoc false`
    * `:file` – file name reported for compiled code (`compile/2` only)
  """

  alias AshGrpc.Proto.{IR, Render, WellKnown}
  alias Google.Protobuf, as: PB

  require IR

  @locals_without_parens [field: 2, field: 3, oneof: 2, rpc: 3, extend: 4, extensions: 1]
  @ident ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # max field number + 1 (exclusive end of `N to max` in message reserved ranges)
  @message_max 536_870_912
  @enum_max 2_147_483_647

  @scalar_types %{
    double: :TYPE_DOUBLE,
    float: :TYPE_FLOAT,
    int64: :TYPE_INT64,
    uint64: :TYPE_UINT64,
    int32: :TYPE_INT32,
    fixed64: :TYPE_FIXED64,
    fixed32: :TYPE_FIXED32,
    bool: :TYPE_BOOL,
    string: :TYPE_STRING,
    bytes: :TYPE_BYTES,
    uint32: :TYPE_UINT32,
    sfixed32: :TYPE_SFIXED32,
    sfixed64: :TYPE_SFIXED64,
    sint32: :TYPE_SINT32,
    sint64: :TYPE_SINT64
  }

  @kind_order %{enum: 0, message: 1, service: 2, stub: 3}

  # -- public API ---------------------------------------------------------------------------

  @doc """
  Quoted module definitions (`defmodule` ASTs), one per message/enum/map
  entry/service/stub, ordered so they can be compiled sequentially (enums,
  messages, services, stubs).
  """
  @spec quoted(IR.Schema.t(), Keyword.t()) :: [{module(), Macro.t()}]
  def quoted(%IR.Schema{} = schema, opts \\ []) do
    schema
    |> definitions(opts)
    |> Enum.sort_by(&Map.fetch!(@kind_order, &1.kind))
    |> Enum.map(&{&1.module, defmodule_ast(&1.module, &1.body)})
  end

  @doc """
  Compiles the modules into the running VM and returns them (in `quoted/2` order).

  Safe to call at compile time and idempotent: a module that is already loaded
  with an identical definition is left alone, a module previously compiled by
  this function with a different definition is replaced, and a module that is
  loaded but was not compiled by AshGrpc (e.g. a `googleapis` or
  protoc-generated module) is kept as is.

  Modules compiled this way live in memory only. Macros that want the modules
  persisted in `.beam` files should inject the ASTs from `quoted/2` instead.
  """
  @spec compile(IR.Schema.t(), Keyword.t()) :: [module()]
  def compile(%IR.Schema{} = schema, opts \\ []) do
    file = Keyword.get(opts, :file, "nofile")

    schema
    |> definitions(opts)
    |> Enum.sort_by(&Map.fetch!(@kind_order, &1.kind))
    |> Enum.map(fn %{module: module, body: body} ->
      hash = :sha256 |> :crypto.hash(:erlang.term_to_binary(body)) |> Base.encode16()

      :global.trans({__MODULE__, module}, fn -> maybe_compile(module, body, hash, file) end)
      module
    end)
  end

  @doc """
  Formatted Elixir source files, as `{relative_path, source}` (used by
  `mix ash_grpc.import`). One file per IR file, named like protoc-gen-elixir
  names them (`acme/shop/v1/shop.proto` → `acme/shop/v1/shop.pb.ex`).
  """
  @spec to_source(IR.Schema.t(), Keyword.t()) :: [{Path.t(), String.t()}]
  def to_source(%IR.Schema{} = schema, opts \\ []) do
    definitions = definitions(schema, opts)

    for %IR.File{path: path} <- schema.files do
      source =
        definitions
        |> Enum.filter(&(&1.file == path))
        |> Enum.sort_by(&Map.fetch!(@kind_order, &1.kind))
        |> Enum.map_join("\n", &module_source/1)

      {Path.rootname(path) <> ".pb.ex", source}
    end
  end

  @doc """
  Builds the `Google.Protobuf.FileDescriptorProto` of an IR file, as `protoc`
  would produce it from the rendered `.proto` (without source info).
  """
  @spec file_descriptor(IR.File.t(), Keyword.t()) :: PB.FileDescriptorProto.t()
  def file_descriptor(%IR.File{} = file, _opts \\ []) do
    ensure_compilable!(file)
    {imports, public} = imports(file)

    normalize(%PB.FileDescriptorProto{
      name: file.path,
      package: blank_to_nil(file.package),
      dependency: imports,
      public_dependency: public,
      message_type: Enum.map(file.messages, &message_descriptor(&1, file)),
      enum_type: Enum.map(file.enums, &enum_descriptor/1),
      service: Enum.map(file.services, &service_descriptor/1),
      options: options_struct(PB.FileOptions, file.options),
      # protoc leaves `syntax` unset for proto2 files
      syntax: if(file.syntax == :proto3, do: "proto3")
    })
  end

  @doc "A `Google.Protobuf.FileDescriptorSet` with one descriptor per schema file."
  @spec file_descriptor_set(IR.Schema.t(), Keyword.t()) :: PB.FileDescriptorSet.t()
  def file_descriptor_set(%IR.Schema{files: files}, opts \\ []) do
    %PB.FileDescriptorSet{file: Enum.map(files, &file_descriptor(&1, opts))}
  end

  @doc """
  The `GRPC.Stub` module generated for a service module.

      iex> AshGrpc.Proto.Compiler.stub_module(Acme.UserService.Service)
      Acme.UserService.Stub

      iex> AshGrpc.Proto.Compiler.stub_module(Acme.UserService)
      Acme.UserService.Stub
  """
  @spec stub_module(module()) :: module()
  def stub_module(service_module) do
    case Module.split(service_module) do
      [_ | _] = parts when length(parts) > 1 ->
        if List.last(parts) == "Service",
          do: Module.concat(Enum.drop(parts, -1) ++ ["Stub"]),
          else: Module.concat(service_module, Stub)

      _ ->
        Module.concat(service_module, Stub)
    end
  end

  @doc """
  The Elixir module used for a proto full name: the `module` of the schema node
  when present, otherwise well-known types, the `:modules` option and finally
  the protoc-gen-elixir naming convention.
  """
  @spec module_for(IR.Schema.t(), IR.full_name(), Keyword.t()) :: module()
  def module_for(%IR.Schema{} = schema, full_name, opts \\ []) do
    resolve_module(type_index(schema), full_name, opts)
  end

  # -- definitions --------------------------------------------------------------------------

  defp definitions(schema, opts) do
    index = type_index(schema)
    ctx = %{index: index, opts: opts, version: protobuf_version()}

    Enum.flat_map(schema.files, fn file ->
      ensure_compilable!(file)
      ctx = Map.merge(ctx, %{file: file, syntax: file.syntax})

      enums = Enum.map(file.enums, &enum_definition(&1, ctx))
      messages = Enum.flat_map(file.messages, &message_definitions(&1, ctx))
      services = Enum.flat_map(file.services, &service_definitions(&1, ctx))

      enums ++ messages ++ services
    end)
  end

  defp ensure_compilable!(%IR.File{syntax: syntax}) when syntax in [:proto2, :proto3], do: :ok

  defp ensure_compilable!(%IR.File{syntax: syntax, path: path}) do
    raise ArgumentError,
          "#{path}: cannot compile syntax #{inspect(syntax)} (only proto2 and proto3 are supported)"
  end

  defp definition(kind, module, ctx, body),
    do: %{kind: kind, module: module, file: ctx.file.path, body: body}

  # -- enums --------------------------------------------------------------------------------

  defp enum_definition(%IR.Enum{} = enum, ctx) do
    module = node_module(enum, ctx)

    use_opts = [
      enum: true,
      full_name: enum.full_name,
      protoc_gen_elixir_version: ctx.version,
      syntax: ctx.syntax
    ]

    fields =
      Enum.map(enum.values, fn value ->
        quote do: field(unquote(atom!(value.name, "enum value")), unquote(value.number))
      end)

    body =
      [moduledoc(enum.doc, ctx), quote(do: use(Protobuf, unquote(use_opts)))] ++
        [descriptor_def(enum_descriptor(enum))] ++ fields

    definition(:enum, module, ctx, body)
  end

  # -- messages -----------------------------------------------------------------------------

  defp message_definitions(%IR.Message{} = message, ctx) do
    module = node_module(message, ctx)
    fields = declaration_order(message.fields)
    real_oneofs = real_oneofs(message)
    oneof_index = real_oneofs |> Enum.with_index() |> Map.new(fn {o, i} -> {o.name, i} end)

    use_opts =
      [
        deprecated: option_value(message.options, "deprecated") == true,
        full_name: message.full_name,
        protoc_gen_elixir_version: ctx.version,
        syntax: ctx.syntax
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false] end)

    oneofs =
      real_oneofs
      |> Enum.with_index()
      |> Enum.map(fn {oneof, index} ->
        quote do: oneof(unquote(atom!(oneof.name, "oneof")), unquote(index))
      end)

    field_asts =
      Enum.map(fields, fn field ->
        args = [
          atom!(field.name, "field"),
          field.number,
          field_opts(field, message, oneof_index, ctx)
        ]

        quote do: field(unquote_splicing(args))
      end)

    body =
      [moduledoc(message.doc, ctx), quote(do: use(Protobuf, unquote(use_opts)))] ++
        [descriptor_def(message_descriptor(message, ctx.file))] ++ oneofs ++ field_asts

    nested_enums = Enum.map(message.nested_enums, &enum_definition(&1, ctx))
    nested_messages = Enum.flat_map(message.nested_messages, &message_definitions(&1, ctx))
    map_entries = Enum.flat_map(fields, &map_entry_definition(&1, message, module, ctx))

    nested_enums ++ nested_messages ++ map_entries ++ [definition(:message, module, ctx, body)]
  end

  defp field_opts(%IR.Field{} = field, message, oneof_index, ctx) do
    {label_opts, type} = label_and_type(field, message, ctx)

    json_name = json_name(field)

    extra =
      [
        json_name: if(json_name != field.name, do: json_name),
        map: if(match?({:map, _, _}, field.type), do: true),
        default: if(ctx.syntax == :proto2, do: field.default),
        enum: if(enum_type?(field.type), do: true),
        oneof: if(field.oneof, do: Map.fetch!(oneof_index, field.oneof)),
        packed: option_value(field.options, "packed"),
        deprecated:
          if(field.deprecated?, do: true, else: option_value(field.options, "deprecated"))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    label_opts ++ [type: type] ++ extra
  end

  defp label_and_type(%IR.Field{type: {:map, _, _}} = field, message, ctx) do
    {[repeated: true], map_entry_module(field, node_module(message, ctx))}
  end

  defp label_and_type(%IR.Field{} = field, _message, ctx) do
    type = type_ast(field.type, ctx)

    label_opts =
      case {ctx.syntax, field.label} do
        {_, :repeated} ->
          [repeated: true]

        {:proto3, :optional} ->
          if field.oneof, do: [], else: [proto3_optional: true]

        {:proto3, nil} ->
          []

        {:proto3, :required} ->
          raise ArgumentError, "field #{field.name}: `required` is not allowed in proto3"

        {:proto2, :required} ->
          [required: true]

        {:proto2, _} ->
          [optional: true]
      end

    {label_opts, type}
  end

  defp type_ast(scalar, _ctx) when IR.is_scalar(scalar), do: scalar

  defp type_ast({kind, name}, ctx) when kind in [:message, :enum],
    do: resolve_module(ctx.index, name, ctx.opts)

  defp enum_type?({:enum, _}), do: true
  defp enum_type?(_), do: false

  defp map_entry_definition(%IR.Field{type: {:map, key, value}} = field, message, parent, ctx) do
    module = map_entry_module(field, parent)

    use_opts = [
      full_name: message.full_name <> "." <> map_entry_name(field.name),
      map: true,
      protoc_gen_elixir_version: ctx.version,
      syntax: ctx.syntax
    ]

    label = if ctx.syntax == :proto2, do: [optional: true], else: []
    value_opts = if enum_type?(value), do: [enum: true], else: []

    body = [
      quote(do: @moduledoc(false)),
      quote(do: use(Protobuf, unquote(use_opts))),
      descriptor_def(map_entry_descriptor(field)),
      quote(do: field(:key, 1, unquote(label ++ [type: key]))),
      quote(do: field(:value, 2, unquote(label ++ [type: type_ast(value, ctx)] ++ value_opts)))
    ]

    [definition(:message, module, ctx, body)]
  end

  defp map_entry_definition(_field, _message, _parent, _ctx), do: []

  defp map_entry_module(field, parent),
    do: Module.concat(parent, Macro.camelize(map_entry_name(field.name)))

  # protoc's MapEntryName: CamelCase of the field name + "Entry"
  defp map_entry_name(field_name) do
    {chars, _} =
      field_name
      |> String.graphemes()
      |> Enum.flat_map_reduce(true, fn
        "_", _cap? -> {[], true}
        char, true -> {[String.upcase(char)], false}
        char, false -> {[char], false}
      end)

    Enum.join(chars) <> "Entry"
  end

  # Oneof members are declared together where the first member appears (that is
  # how `AshGrpc.Proto.Render` prints them, so descriptors match protoc's).
  defp declaration_order(fields) do
    {ordered, _} =
      Enum.flat_map_reduce(fields, MapSet.new(), fn field, seen ->
        cond do
          is_nil(field.oneof) -> {[field], seen}
          MapSet.member?(seen, field.oneof) -> {[], seen}
          true -> {Enum.filter(fields, &(&1.oneof == field.oneof)), MapSet.put(seen, field.oneof)}
        end
      end)

    ordered
  end

  defp real_oneofs(%IR.Message{oneofs: oneofs, fields: fields}) do
    used = fields |> Enum.map(& &1.oneof) |> Enum.reject(&is_nil/1) |> MapSet.new()
    declared = Enum.map(oneofs, & &1.name)

    # oneofs referenced by fields but not declared get an implicit declaration
    implicit =
      fields
      |> Enum.map(& &1.oneof)
      |> Enum.reject(&(is_nil(&1) or &1 in declared))
      |> Enum.uniq()
      |> Enum.map(&%IR.Oneof{name: &1})

    Enum.filter(oneofs, &MapSet.member?(used, &1.name)) ++ implicit
  end

  # -- services -----------------------------------------------------------------------------

  defp service_definitions(%IR.Service{} = service, ctx) do
    module = node_module(service, ctx)

    rpcs =
      Enum.map(service.rpcs, fn rpc ->
        input = resolve_module(ctx.index, rpc.input, ctx.opts)
        output = resolve_module(ctx.index, rpc.output, ctx.opts)
        input = if rpc.client_streaming?, do: quote(do: stream(unquote(input))), else: input
        output = if rpc.server_streaming?, do: quote(do: stream(unquote(output))), else: output
        name = atom!(rpc.name, "rpc")

        # AshGrpc.Client reads idempotency from the rpc options to decide on retries.
        case rpc.idempotency_level do
          level when level in [:no_side_effects, :idempotent] ->
            options = Macro.escape(%{idempotency_level: level})
            quote do: rpc(unquote(name), unquote(input), unquote(output), unquote(options))

          _ ->
            quote do: rpc(unquote(name), unquote(input), unquote(output))
        end
      end)

    use_opts = [name: service.full_name, protoc_gen_elixir_version: ctx.version]

    body =
      [moduledoc(service.doc, ctx), quote(do: use(GRPC.Service, unquote(use_opts)))] ++
        [descriptor_def(service_descriptor(service))] ++ rpcs

    stub_body = [
      quote(do: @moduledoc(false)),
      quote(do: use(GRPC.Stub, service: unquote(module)))
    ]

    [
      definition(:service, module, ctx, body),
      definition(:stub, stub_module(module), ctx, stub_body)
    ]
  end

  # -- descriptors --------------------------------------------------------------------------

  defp message_descriptor(%IR.Message{} = message, file) do
    fields = declaration_order(message.fields)
    real_oneofs = real_oneofs(message)
    oneof_index = real_oneofs |> Enum.with_index() |> Map.new(fn {o, i} -> {o.name, i} end)

    synthetic =
      if file.syntax == :proto3,
        do: Enum.filter(fields, &(&1.label == :optional and is_nil(&1.oneof))),
        else: []

    synthetic_index =
      synthetic
      |> Enum.with_index(length(real_oneofs))
      |> Map.new(fn {field, index} -> {field.name, index} end)

    oneof_decls =
      Enum.map(real_oneofs, fn oneof ->
        %PB.OneofDescriptorProto{
          name: oneof.name,
          options: options_struct(PB.OneofOptions, oneof.options)
        }
      end) ++ Enum.map(synthetic, &%PB.OneofDescriptorProto{name: "_" <> &1.name})

    map_entries =
      fields
      |> Enum.filter(&match?({:map, _, _}, &1.type))
      |> Enum.map(&map_entry_descriptor/1)

    %PB.DescriptorProto{
      name: message.name,
      field:
        Enum.map(fields, fn field ->
          field_descriptor(
            field,
            message,
            file,
            oneof_index[field.oneof] || synthetic_index[field.name]
          )
        end),
      nested_type:
        map_entries ++ Enum.map(message.nested_messages, &message_descriptor(&1, file)),
      enum_type: Enum.map(message.nested_enums, &enum_descriptor/1),
      oneof_decl: oneof_decls,
      reserved_range:
        Enum.map(ranges(message.reserved_numbers, @message_max - 1), fn {from, to} ->
          %PB.DescriptorProto.ReservedRange{start: from, end: to + 1}
        end),
      reserved_name: Enum.sort(Enum.uniq(message.reserved_names)),
      options: options_struct(PB.MessageOptions, message.options)
    }
    |> normalize()
  end

  defp field_descriptor(%IR.Field{} = field, message, file, oneof_index) do
    {type, type_name} = descriptor_type(field, message)

    field_options =
      if field.deprecated? and not has_option?(field.options, "deprecated"),
        do: [%IR.Option{name: "deprecated", value: true} | field.options],
        else: field.options

    %PB.FieldDescriptorProto{
      name: field.name,
      number: field.number,
      label: descriptor_label(field),
      type: type,
      type_name: type_name,
      default_value: default_value(field.default, field.type, file.syntax),
      oneof_index: oneof_index,
      json_name: json_name(field),
      options: options_struct(PB.FieldOptions, field_options),
      proto3_optional:
        if(file.syntax == :proto3 and field.label == :optional and is_nil(field.oneof), do: true)
    }
  end

  defp descriptor_type(%IR.Field{type: {:map, _, _}, name: name}, message),
    do: {:TYPE_MESSAGE, "." <> message.full_name <> "." <> map_entry_name(name)}

  defp descriptor_type(%IR.Field{type: {:message, name}}, _message),
    do: {:TYPE_MESSAGE, "." <> name}

  defp descriptor_type(%IR.Field{type: {:enum, name}}, _message), do: {:TYPE_ENUM, "." <> name}

  defp descriptor_type(%IR.Field{type: scalar}, _message),
    do: {Map.fetch!(@scalar_types, scalar), nil}

  defp descriptor_label(%IR.Field{type: {:map, _, _}}), do: :LABEL_REPEATED
  defp descriptor_label(%IR.Field{label: :repeated}), do: :LABEL_REPEATED
  defp descriptor_label(%IR.Field{label: :required}), do: :LABEL_REQUIRED
  defp descriptor_label(%IR.Field{}), do: :LABEL_OPTIONAL

  defp map_entry_descriptor(%IR.Field{type: {:map, key, value}} = field) do
    {value_type, value_type_name} =
      case value do
        {:message, name} -> {:TYPE_MESSAGE, "." <> name}
        {:enum, name} -> {:TYPE_ENUM, "." <> name}
        scalar -> {Map.fetch!(@scalar_types, scalar), nil}
      end

    %PB.DescriptorProto{
      name: map_entry_name(field.name),
      field: [
        %PB.FieldDescriptorProto{
          name: "key",
          number: 1,
          label: :LABEL_OPTIONAL,
          type: Map.fetch!(@scalar_types, key),
          json_name: "key"
        },
        %PB.FieldDescriptorProto{
          name: "value",
          number: 2,
          label: :LABEL_OPTIONAL,
          type: value_type,
          type_name: value_type_name,
          json_name: "value"
        }
      ],
      options: %PB.MessageOptions{map_entry: true}
    }
    |> normalize()
  end

  defp enum_descriptor(%IR.Enum{} = enum) do
    options =
      if enum.allow_alias? and not has_option?(enum.options, "allow_alias"),
        do: [%IR.Option{name: "allow_alias", value: true} | enum.options],
        else: enum.options

    %PB.EnumDescriptorProto{
      name: enum.name,
      value:
        Enum.map(enum.values, fn value ->
          value_options =
            if value.deprecated? and not has_option?(value.options, "deprecated"),
              do: [%IR.Option{name: "deprecated", value: true} | value.options],
              else: value.options

          %PB.EnumValueDescriptorProto{
            name: value.name,
            number: value.number,
            options: options_struct(PB.EnumValueOptions, value_options)
          }
        end),
      options: options_struct(PB.EnumOptions, options),
      reserved_range:
        Enum.map(ranges(enum.reserved_numbers, @enum_max), fn {from, to} ->
          %PB.EnumDescriptorProto.EnumReservedRange{start: from, end: to}
        end),
      reserved_name: Enum.sort(Enum.uniq(enum.reserved_names))
    }
    |> normalize()
  end

  defp service_descriptor(%IR.Service{} = service) do
    %PB.ServiceDescriptorProto{
      name: service.name,
      method:
        Enum.map(service.rpcs, fn rpc ->
          extra =
            if(rpc.deprecated? and not has_option?(rpc.options, "deprecated"),
              do: [%IR.Option{name: "deprecated", value: true}],
              else: []
            ) ++
              if(rpc.idempotency_level && not has_option?(rpc.options, "idempotency_level"),
                do: [
                  %IR.Option{name: "idempotency_level", value: idempotency(rpc.idempotency_level)}
                ],
                else: []
              )

          %PB.MethodDescriptorProto{
            name: rpc.name,
            input_type: "." <> rpc.input,
            output_type: "." <> rpc.output,
            options: options_struct(PB.MethodOptions, extra ++ rpc.options),
            client_streaming: if(rpc.client_streaming?, do: true),
            server_streaming: if(rpc.server_streaming?, do: true)
          }
        end),
      options: options_struct(PB.ServiceOptions, service.options)
    }
    |> normalize()
  end

  defp idempotency(:no_side_effects), do: :NO_SIDE_EFFECTS
  defp idempotency(:idempotent), do: :IDEMPOTENT
  defp idempotency(:idempotency_unknown), do: :IDEMPOTENCY_UNKNOWN

  defp imports(%IR.File{imports: imports, public_imports: public}) do
    all = (imports ++ public) |> Enum.uniq() |> Enum.sort()

    public_indexes =
      all
      |> Enum.with_index()
      |> Enum.filter(fn {path, _} -> path in public end)
      |> Enum.map(&elem(&1, 1))

    {all, public_indexes}
  end

  # Sorted ranges as `{from, to}` (inclusive); `max` replaced by `max_value`.
  defp ranges(numbers, max_value) do
    numbers
    |> Enum.map(fn
      {from, :max} -> {from, max_value}
      {from, to} -> {from, to}
      number -> {number, number}
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Standard options only: names that are fields of the options message. Custom
  # `(ext).opt` options and pseudo-options (`json_name`, `default`) are skipped.
  defp options_struct(module, options) do
    names = option_fields(module)

    attrs =
      for %IR.Option{name: name, value: value} <- options,
          Map.has_key?(names, name),
          do: {Map.fetch!(names, name), value}

    if attrs == [], do: nil, else: struct!(module, attrs)
  end

  defp option_fields(module) do
    Map.new(module.__message_props__().field_props, fn {_fnum, props} ->
      {props.name, props.name_atom}
    end)
  end

  defp default_value(nil, _type, _syntax), do: nil
  defp default_value(_default, _type, :proto3), do: nil
  defp default_value(value, _type, _syntax) when is_boolean(value), do: Atom.to_string(value)
  defp default_value(value, _type, _syntax) when is_atom(value), do: Atom.to_string(value)
  defp default_value(value, _type, _syntax) when is_integer(value), do: Integer.to_string(value)

  defp default_value(value, _type, _syntax) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15,
      do: value |> trunc() |> Integer.to_string(),
      else: Float.to_string(value)
  end

  defp default_value(value, :bytes, _syntax) when is_binary(value), do: c_escape(value)
  defp default_value(value, _type, _syntax) when is_binary(value), do: value

  defp c_escape(binary), do: for(<<byte <- binary>>, into: "", do: c_escape_byte(byte))

  defp c_escape_byte(?\n), do: "\\n"
  defp c_escape_byte(?\r), do: "\\r"
  defp c_escape_byte(?\t), do: "\\t"
  defp c_escape_byte(?"), do: "\\\""
  defp c_escape_byte(?'), do: "\\'"
  defp c_escape_byte(?\\), do: "\\\\"

  defp c_escape_byte(byte) when byte < 0x20 or byte >= 0x7F,
    do: "\\" <> (byte |> Integer.to_string(8) |> String.pad_leading(3, "0"))

  defp c_escape_byte(byte), do: <<byte>>

  # Same normalisation protoc-gen-elixir applies: encode and decode, so unset
  # fields look exactly like in descriptors decoded from protoc output.
  defp normalize(%module{} = descriptor), do: descriptor |> module.encode() |> module.decode()

  defp descriptor_def(descriptor) do
    body =
      descriptor
      |> inspect(limit: :infinity, printable_limit: :infinity)
      |> Code.string_to_quoted!()

    quote do
      def descriptor do
        unquote(body)
      end
    end
  end

  # -- helpers ------------------------------------------------------------------------------

  defp moduledoc(doc, ctx) do
    if is_binary(doc) and doc != "" and Keyword.get(ctx.opts, :docs, true),
      do: quote(do: @moduledoc(unquote(doc))),
      else: quote(do: @moduledoc(false))
  end

  defp json_name(%IR.Field{json_name: nil, name: name, options: options}),
    do: option_value(options, "json_name") || Render.default_json_name(name)

  defp json_name(%IR.Field{json_name: json_name}), do: json_name

  defp has_option?(options, name), do: Enum.any?(options, &(&1.name == name))

  defp option_value(options, name) do
    Enum.find_value(options, fn
      %IR.Option{name: ^name, value: value} -> value
      _ -> nil
    end)
  end

  defp node_module(%{module: module}, _ctx) when not is_nil(module), do: module
  defp node_module(%{full_name: full_name}, _ctx), do: default_module(full_name)

  defp type_index(%IR.Schema{files: files}) do
    files
    |> Enum.flat_map(fn file ->
      types(file.messages, file.enums) ++ Enum.map(file.services, &{&1.full_name, &1.module})
    end)
    |> Enum.reject(fn {_name, module} -> is_nil(module) end)
    |> Map.new()
  end

  defp types(messages, enums) do
    Enum.map(enums, &{&1.full_name, &1.module}) ++
      Enum.flat_map(messages, fn message ->
        [
          {message.full_name, message.module}
          | types(message.nested_messages, message.nested_enums)
        ]
      end)
  end

  defp resolve_module(index, full_name, opts) do
    Map.get(index, full_name) || WellKnown.module(full_name) ||
      Map.get(Keyword.get(opts, :modules, %{}), full_name) || default_module(full_name)
  end

  defp default_module(full_name) do
    full_name
    |> String.split(".")
    |> Enum.map(fn segment -> segment |> validate!("name segment") |> Macro.camelize() end)
    |> Module.concat()
  end

  # Names are validated before becoming atoms; IR names come from builders or
  # from protoc-validated foreign .proto files, never from request payloads.
  defp atom!(name, what), do: name |> validate!(what) |> String.to_atom()

  defp validate!(name, what) do
    if is_binary(name) and Regex.match?(@ident, name),
      do: name,
      else: raise(ArgumentError, "invalid #{what} name: #{inspect(name)}")
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp protobuf_version do
    case Application.spec(:protobuf, :vsn) do
      nil -> "0.0.0"
      vsn -> List.to_string(vsn)
    end
  end

  defp defmodule_ast(module, body) do
    quote do
      defmodule unquote(module) do
        (unquote_splicing(body))
      end
    end
  end

  defp module_source(%{module: module, body: body}) do
    module
    |> defmodule_ast(body)
    |> Code.quoted_to_algebra(locals_without_parens: @locals_without_parens)
    |> Inspect.Algebra.format(98)
    |> IO.iodata_to_binary()
    |> String.replace(
      "  def descriptor do\n",
      "  def descriptor do\n    # credo:disable-for-next-line\n"
    )
    |> Kernel.<>("\n")
  end

  defp maybe_compile(module, body, hash, file) do
    case loaded_hash(module) do
      ^hash ->
        :unchanged

      :foreign ->
        :foreign

      previous ->
        if previous != :not_loaded do
          :code.purge(module)
          :code.delete(module)
        end

        hash_attr =
          quote do
            Module.register_attribute(__MODULE__, :ash_grpc_hash, persist: true)
            @ash_grpc_hash unquote(hash)
          end

        Code.compile_quoted(defmodule_ast(module, [hash_attr | body]), file)
        :compiled
    end
  end

  defp loaded_hash(module) do
    if Code.ensure_loaded?(module) do
      case Keyword.get(module.__info__(:attributes), :ash_grpc_hash) do
        [hash] -> hash
        nil -> :foreign
      end
    else
      :not_loaded
    end
  end
end
