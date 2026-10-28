defmodule AshGrpc.Type.Mapping do
  @moduledoc """
  Maps Ash types to protobuf field types.

  | Ash type | proto (default) | alternative `representation:` |
  |---|---|---|
  | `:string`, `:ci_string` | `string` | `bytes`, `google.protobuf.StringValue` |
  | `:integer` | `int64` | any integer scalar, `string`, `google.protobuf.{Int64,Int32,UInt64,UInt32,String}Value` |
  | `:float` | `double` | `float`, `string`, `google.protobuf.{Double,Float}Value` |
  | `:decimal` | `string` | `google.type.Decimal`, `google.protobuf.StringValue` (never a float) |
  | `:boolean` | `bool` | `google.protobuf.BoolValue` |
  | `:uuid`, `:uuid_v7` | `string` | `bytes` (16 raw bytes), `google.protobuf.{String,Bytes}Value` |
  | `:binary`, `:url_encoded_binary` | `bytes` | `google.protobuf.BytesValue` |
  | `:atom` (no `one_of`), `:module` | `string` | `google.protobuf.StringValue` |
  | `:date` | `google.type.Date` | `string` (ISO-8601) |
  | `:time`, `:time_usec` | `google.type.TimeOfDay` | `string` (ISO-8601) |
  | `:utc_datetime(_usec)`, `:datetime` | `google.protobuf.Timestamp` | `string` (ISO-8601) |
  | `:naive_datetime` | `string` (ISO-8601) | |
  | `:duration` | `google.protobuf.Duration` | `string` (ISO-8601) |
  | `Ash.Type.Enum`, `:atom` with `one_of` | `enum` (`<PREFIX>_UNSPECIFIED = 0`) | `string` |
  | `:map`/`:struct`/`:keyword` without `fields` | `google.protobuf.Struct` | `string` (JSON) |
  | `:map`/`:struct`/`:keyword`/`:tuple` with `fields` | nested message | `google.protobuf.Struct`, `string` (JSON) |
  | `Ash.Type.Union` | wrapper message with a `oneof value` | `google.protobuf.Struct`, `string` (JSON) |
  | embedded resource / `:struct` with `instance_of` a resource | the resource message (`:resolve_resource`) | |
  | `:vector` | `repeated float` | |
  | `{:array, t}` | `repeated t` (wrapper messages for nil items, nested arrays, `distinguish_nil?`) | applies to the items |
  | `:term` | — (`{:error, {:unsupported, ...}}`) | `google.protobuf.Value`, `google.protobuf.Struct`, `string` (JSON) |
  | `:function`, `:file`, `:range` | — | |

  Types implementing `AshGrpc.Type` decide their own mapping (`proto_type/1`);
  NewTypes are unwrapped otherwise.

  ## Generated definitions

  Some types need extra definitions which are returned in `Result.messages`
  and `Result.enums` (the caller puts them into the file and deduplicates them
  by `full_name`). Their names are derived from `:name_hint`, numbers are
  assigned in declaration order starting at 1 (the lock may override them):

    * enums: `Ash.Type.Enum` (and NewTypes of `:atom` with `one_of`) are named
      after their module (`MyApp.UserRole` → `UserRole`), anonymous
      `:atom` + `one_of` after `:name_hint`. Values are
      `<UPPER_SNAKE(enum name)>_<UPPER_SNAKE(value)>`; enum value `source` is the
      Ash value. Enum `source` is `{:type, type, constraints}`.
    * typed maps: message `<hint>`, one field per key (`source:
      {:field, key, type, constraints}`); nested types are named `<hint><Key>`.
      Message `source` is `{:type, type, constraints}`.
    * unions: message `<hint>` with `oneof value { ... }` and one field per
      member (`source: {:member, name, type, constraints}`). Message `source` is
      `{:type, Ash.Type.Union, constraints}`.
    * `{:array, t}` whose items may be `nil` (`nil_items?: true`) or map to a
      proto map/repeated field: `repeated <hint>Item`, where
      `message <hint>Item { optional t value = 1; }` (`source:
      {:item_wrapper, t, item_constraints}`; an empty item means `nil`).
    * a list value of nesting depth `d` that has to be a message (nested arrays,
      array union members, `distinguish_nil?: true`): `<hint><"List" × d>` with
      `repeated ... values = 1` (`source: {:list_wrapper, list_type, constraints}`).
    * wrapper fields have `source: {:wrapped, type, constraints}`.

  Embedded resources (and `:struct` with `instance_of` a resource) are owned by
  the schema builder: they map to `{:message, resolve_resource.(resource)}`.

  ## Options

    * `:allow_nil?` – whether the value may be `nil` (default `true`). Nullable
      scalars and enums get `label: :optional` (explicit presence).
    * `:package` – proto package used for generated messages/enums.
    * `:name_hint` – base name for generated messages/enums (e.g. `"UserRole"`).
      Required for types that generate anonymous definitions.
    * `:module_prefix` – when given, generated messages/enums get
      `module: Module.concat(prefix, name)`; otherwise `module` is `nil` and the
      builder fills it in.
    * `:representation` – per-field override of the default representation,
      e.g. `:string`, `:int32`, `{:message, "google.type.Decimal"}` (see table).
      For arrays it applies to the items.
    * `:distinguish_nil?` – for nullable arrays: wrap the list into a
      `<hint>List` message so that `nil` and `[]` are distinguishable.
    * `:resolve_resource` – `(resource -> full_name)`, resolves the message of an
      embedded resource. Without it embedded resources are an error.
  """

  alias AshGrpc.Proto.IR
  alias AshGrpc.Type.{Kind, Known, Naming}
  require IR

  defmodule Result do
    @moduledoc """
    Result of mapping an Ash type.

      * `type`/`label` – go straight into `AshGrpc.Proto.IR.Field`
      * `messages`/`enums` – extra top-level definitions the type needs
        (deduplicated by `full_name` by the caller)
      * `imports` – import paths the file needs
    """
    defstruct [:type, label: nil, messages: [], enums: [], imports: []]

    @type t :: %__MODULE__{
            type: IR.field_type(),
            label: IR.label(),
            messages: [IR.Message.t()],
            enums: [IR.Enum.t()],
            imports: [String.t()]
          }
  end

  @int_scalars ~w(int64 int32 sint64 sint32 sfixed64 sfixed32 uint64 uint32 fixed64 fixed32)a

  @string_value {:message, "google.protobuf.StringValue"}
  @bytes_value {:message, "google.protobuf.BytesValue"}
  @struct {:message, "google.protobuf.Struct"}
  @value {:message, "google.protobuf.Value"}
  @timestamp {:message, "google.protobuf.Timestamp"}

  # module => {default, allowed representations}
  @basic %{
    Ash.Type.String => {:string, [:string, :bytes, @string_value]},
    Ash.Type.CiString => {:string, [:string, :bytes, @string_value]},
    Ash.Type.Integer =>
      {:int64,
       @int_scalars ++
         [
           :string,
           @string_value,
           {:message, "google.protobuf.Int64Value"},
           {:message, "google.protobuf.Int32Value"},
           {:message, "google.protobuf.UInt64Value"},
           {:message, "google.protobuf.UInt32Value"}
         ]},
    Ash.Type.Float =>
      {:double,
       [
         :double,
         :float,
         :string,
         {:message, "google.protobuf.DoubleValue"},
         {:message, "google.protobuf.FloatValue"}
       ]},
    Ash.Type.Decimal => {:string, [:string, @string_value, {:message, "google.type.Decimal"}]},
    Ash.Type.Boolean => {:bool, [:bool, {:message, "google.protobuf.BoolValue"}]},
    Ash.Type.UUID => {:string, [:string, :bytes, @string_value, @bytes_value]},
    Ash.Type.UUIDv7 => {:string, [:string, :bytes, @string_value, @bytes_value]},
    Ash.Type.Binary => {:bytes, [:bytes, @bytes_value]},
    Ash.Type.UrlEncodedBinary => {:bytes, [:bytes, @bytes_value]},
    Ash.Type.Atom => {:string, [:string, @string_value]},
    Ash.Type.Module => {:string, [:string, @string_value]},
    Ash.Type.Date => {{:message, "google.type.Date"}, [{:message, "google.type.Date"}, :string]},
    Ash.Type.Time =>
      {{:message, "google.type.TimeOfDay"}, [{:message, "google.type.TimeOfDay"}, :string]},
    Ash.Type.TimeUsec =>
      {{:message, "google.type.TimeOfDay"}, [{:message, "google.type.TimeOfDay"}, :string]},
    Ash.Type.NaiveDatetime => {:string, [:string]},
    Ash.Type.UtcDatetime => {@timestamp, [@timestamp, :string]},
    Ash.Type.UtcDatetimeUsec => {@timestamp, [@timestamp, :string]},
    Ash.Type.DateTime => {@timestamp, [@timestamp, :string]},
    Ash.Type.Duration =>
      {{:message, "google.protobuf.Duration"}, [{:message, "google.protobuf.Duration"}, :string]},
    Ash.Type.Map => {@struct, [@struct, :string]},
    Ash.Type.Struct => {@struct, [@struct, :string]},
    Ash.Type.Keyword => {@struct, [@struct, :string]}
  }

  @doc """
  Maps an Ash type (short name or module, may be `{:array, type}`) to a proto field type.

  See the module documentation for the table and the options.
  """
  @spec to_proto(Ash.Type.t(), Keyword.t(), Keyword.t()) :: {:ok, Result.t()} | {:error, term()}
  def to_proto(type, constraints \\ [], opts \\ []) do
    constraints = constraints || []
    kind = Kind.classify(type, constraints)

    result =
      case {kind, opts[:representation]} do
        {{:array, inner, item_constraints, array_constraints}, _} ->
          map_array(inner, item_constraints, array_constraints, opts)

        {kind, nil} ->
          map_kind(kind, constraints, opts)

        {kind, representation} ->
          represent(kind, representation)
      end

    with {:ok, result} <- result, do: {:ok, finalize(result, opts)}
  end

  @doc "Default and allowed representations of a basic (scalar-like) Ash type module."
  @spec representations(module()) :: {IR.field_type(), [IR.field_type()]} | nil
  def representations(module), do: Map.get(@basic, module)

  @doc "Nesting depth of an array type (`{:array, {:array, :string}}` → 2)."
  @spec array_depth(Ash.Type.t()) :: non_neg_integer()
  def array_depth({:array, inner}), do: 1 + array_depth(inner)
  def array_depth(_), do: 0

  ## kinds

  defp map_kind({:custom, module, constraints}, _, _opts) do
    case module.proto_type(constraints) do
      {:ok, %Result{} = result} -> {:ok, result}
      {:error, _} = error -> error
      other -> {:error, {:invalid_proto_type, module, other}}
    end
  end

  defp map_kind({:enum, values, module}, constraints, opts),
    do: map_enum(values, module, constraints, opts)

  defp map_kind({:resource, resource}, _constraints, opts) do
    case opts[:resolve_resource] do
      resolve when is_function(resolve, 1) ->
        case resolve.(resource) do
          full_name when is_binary(full_name) ->
            {:ok, %Result{type: {:message, full_name}}}

          {:ok, full_name} when is_binary(full_name) ->
            {:ok, %Result{type: {:message, full_name}}}

          other ->
            {:error, {:unresolved_resource, resource, other}}
        end

      _ ->
        {:error,
         {:unsupported, resource,
          "embedded resources are mapped by the schema builder; pass :resolve_resource"}}
    end
  end

  defp map_kind({:fields, base_type, fields}, constraints, opts),
    do: map_fields(base_type, fields, constraints, opts)

  defp map_kind({:union, types}, constraints, opts),
    do: map_union(types, Keyword.put(constraints, :types, types), opts)

  defp map_kind({:unsupported, type}, _constraints, _opts) do
    {:error,
     {:unsupported, type,
      "no protobuf mapping for this Ash type; use `representation:` or implement AshGrpc.Type"}}
  end

  defp map_kind({:basic, Ash.Type.Vector, _}, _constraints, _opts),
    do: {:ok, %Result{type: :float, label: :repeated}}

  defp map_kind({:basic, module, _}, _constraints, _opts) do
    case Map.fetch(@basic, module) do
      {:ok, {default, _}} -> {:ok, %Result{type: default}}
      :error -> {:error, {:unsupported, module, "no protobuf mapping for this Ash type"}}
    end
  end

  ## representation overrides

  defp represent({:custom, _module, _}, representation),
    do: {:ok, %Result{type: representation}}

  defp represent({:basic, module, _} = kind, representation) do
    case Map.fetch(@basic, module) do
      {:ok, {_, allowed}} -> check_representation(kind, representation, allowed)
      :error -> unsupported_representation(kind, representation)
    end
  end

  defp represent({:enum, _, _} = kind, representation),
    do: check_representation(kind, representation, [:string, @string_value])

  defp represent({kind_name, _, _} = kind, representation) when kind_name in [:fields],
    do: check_representation(kind, representation, [@struct, :string])

  defp represent({kind_name, _} = kind, representation) when kind_name in [:union, :resource],
    do: check_representation(kind, representation, [@struct, :string])

  defp represent({:unsupported, Ash.Type.Term} = kind, representation),
    do: check_representation(kind, representation, [@value, @struct, :string])

  defp represent(kind, representation), do: unsupported_representation(kind, representation)

  defp check_representation(kind, representation, allowed) do
    if representation in allowed do
      {:ok, %Result{type: representation}}
    else
      unsupported_representation(kind, representation)
    end
  end

  defp unsupported_representation(kind, representation) do
    {:error, {:unsupported_representation, kind_type(kind), representation}}
  end

  defp kind_type({:basic, module, _}), do: module
  defp kind_type({:enum, _, module}), do: module || Ash.Type.Atom
  defp kind_type({:fields, module, _}), do: module
  defp kind_type({:union, _}), do: Ash.Type.Union
  defp kind_type({:resource, resource}), do: resource
  defp kind_type({_, type}), do: type
  defp kind_type(other), do: other

  ## enums

  defp map_enum(values, module, constraints, opts) do
    with {:ok, name} <- enum_name(module, opts),
         {:ok, enum_values} <- enum_values(name, values, module) do
      full_name = IR.full_name(opts[:package], name)

      enum = %IR.Enum{
        name: name,
        full_name: full_name,
        module: module_for(name, opts),
        doc: enum_doc(module),
        source: {:type, module || Ash.Type.Atom, constraints},
        values: [
          %IR.EnumValue{name: Naming.unspecified_name(name), number: 0, source: nil}
          | enum_values
        ]
      }

      {:ok, %Result{type: {:enum, full_name}, enums: [enum]}}
    end
  end

  defp enum_name(nil, opts), do: hint(opts, Ash.Type.Atom)
  defp enum_name(module, _opts), do: {:ok, Naming.module_short_name(module)}

  defp enum_values(name, values, module) do
    enum_values =
      values
      |> Enum.with_index(1)
      |> Enum.map(fn {value, number} ->
        %IR.EnumValue{
          name: Naming.enum_value_name(name, value),
          number: number,
          doc: value_doc(module, value),
          source: value
        }
      end)

    case duplicates(Enum.map(enum_values, & &1.name)) do
      [] -> {:ok, enum_values}
      dups -> {:error, {:enum_value_collision, name, dups}}
    end
  end

  defp enum_doc(nil), do: nil

  defp enum_doc(module) do
    if function_exported?(module, :description, 0), do: module.description()
  end

  defp value_doc(nil, _value), do: nil

  defp value_doc(module, value) do
    if function_exported?(module, :description, 1), do: module.description(value)
  end

  ## typed maps / structs / keywords / tuples

  defp map_fields(base_type, fields, constraints, opts) do
    with {:ok, name} <- hint(opts, base_type),
         {:ok, ir_fields, results} <- map_message_fields(name, fields, opts) do
      message = %IR.Message{
        name: name,
        full_name: IR.full_name(opts[:package], name),
        module: module_for(name, opts),
        source: {:type, base_type, constraints},
        fields: ir_fields
      }

      {:ok, merge(%Result{type: {:message, message.full_name}, messages: [message]}, results)}
    end
  end

  defp map_message_fields(name, fields, opts) do
    fields
    |> Enum.with_index(1)
    |> reduce_ok({[], []}, fn {{key, config}, number}, {ir_fields, results} ->
      type = config[:type]
      field_constraints = config[:constraints] || []

      sub_opts =
        opts
        |> nested_opts()
        |> Keyword.merge(
          name_hint: name <> Naming.pascal(key),
          allow_nil?: Keyword.get(config, :allow_nil?, true)
        )

      with {:ok, result} <- to_proto(type, field_constraints, sub_opts) do
        field = %IR.Field{
          name: Naming.snake(key),
          number: number,
          type: result.type,
          label: result.label,
          doc: config[:description],
          source: {:field, key, type, field_constraints}
        }

        {:ok, {[field | ir_fields], [result | results]}}
      end
    end)
    |> case do
      {:ok, {ir_fields, results}} ->
        ir_fields = Enum.reverse(ir_fields)

        case duplicates(Enum.map(ir_fields, & &1.name)) do
          [] -> {:ok, ir_fields, Enum.reverse(results)}
          dups -> {:error, {:field_name_collision, name, dups}}
        end

      error ->
        error
    end
  end

  ## unions

  defp map_union(types, constraints, opts) do
    with {:ok, name} <- hint(opts, Ash.Type.Union),
         {:ok, fields, results} <- map_union_members(name, types, opts) do
      message = %IR.Message{
        name: name,
        full_name: IR.full_name(opts[:package], name),
        module: module_for(name, opts),
        source: {:type, Ash.Type.Union, constraints},
        oneofs: [%IR.Oneof{name: "value"}],
        fields: fields
      }

      {:ok, merge(%Result{type: {:message, message.full_name}, messages: [message]}, results)}
    end
  end

  defp map_union_members(name, types, opts) do
    types
    |> Kind.union_members()
    |> Enum.with_index(1)
    |> reduce_ok({[], []}, fn {{member, type, member_constraints}, number}, {fields, results} ->
      sub_opts =
        opts
        |> nested_opts()
        |> Keyword.merge(name_hint: name <> Naming.pascal(member), allow_nil?: false)

      with {:ok, result} <- union_member(type, member_constraints, sub_opts) do
        field = %IR.Field{
          name: Naming.snake(member),
          number: number,
          type: result.type,
          label: nil,
          oneof: "value",
          source: {:member, member, type, member_constraints}
        }

        {:ok, {[field | fields], [result | results]}}
      end
    end)
    |> case do
      {:ok, {fields, results}} ->
        fields = Enum.reverse(fields)

        case duplicates(Enum.map(fields, & &1.name)) do
          [] -> {:ok, fields, Enum.reverse(results)}
          dups -> {:error, {:field_name_collision, name, dups}}
        end

      error ->
        error
    end
  end

  # oneof members can be neither repeated nor maps
  defp union_member({:array, _} = type, constraints, opts),
    do: list_wrapper(type, constraints, opts)

  defp union_member(type, constraints, opts) do
    with {:ok, result} <- to_proto(type, constraints, opts) do
      case result do
        %Result{type: {:map, _, _}} ->
          {:error, {:unsupported, type, "maps cannot be union members"}}

        %Result{label: :repeated} ->
          item_wrapper(type, constraints, Keyword.put(opts, :allow_nil?, false))

        result ->
          {:ok, %{result | label: nil}}
      end
    end
  end

  ## arrays

  defp map_array(inner, item_constraints, array_constraints, opts) do
    if opts[:distinguish_nil?] && Keyword.get(opts, :allow_nil?, true) do
      list_wrapper({:array, inner}, array_constraints, Keyword.delete(opts, :distinguish_nil?))
    else
      repeated(inner, item_constraints, array_constraints, opts)
    end
  end

  defp repeated(inner, item_constraints, array_constraints, opts) do
    item_opts =
      opts
      |> Keyword.delete(:distinguish_nil?)
      |> Keyword.put(:allow_nil?, false)

    result =
      cond do
        match?({:array, _}, inner) ->
          list_wrapper(inner, item_constraints, item_opts)

        array_constraints[:nil_items?] ->
          item_wrapper(inner, item_constraints, item_opts)

        true ->
          plain_items(inner, item_constraints, item_opts)
      end

    with {:ok, result} <- result, do: {:ok, %{result | label: :repeated}}
  end

  # repeated fields can contain neither repeated fields nor maps
  defp plain_items(inner, item_constraints, opts) do
    case to_proto(inner, item_constraints, opts) do
      {:ok, %Result{label: :repeated}} -> item_wrapper(inner, item_constraints, opts)
      {:ok, %Result{type: {:map, _, _}}} -> item_wrapper(inner, item_constraints, opts)
      other -> other
    end
  end

  # `message <hint>List… { repeated <items> values = 1; }`
  defp list_wrapper({:array, inner} = list_type, constraints, opts) do
    with {:ok, base} <- hint(opts, list_type),
         {:ok, values} <-
           repeated(inner, Keyword.get(constraints, :items, []), constraints, opts) do
      name = base <> String.duplicate("List", array_depth(list_type))

      message = %IR.Message{
        name: name,
        full_name: IR.full_name(opts[:package], name),
        module: module_for(name, opts),
        source: {:list_wrapper, list_type, constraints},
        fields: [
          %IR.Field{
            name: "values",
            number: 1,
            type: values.type,
            label: :repeated,
            source: {:wrapped, list_type, constraints}
          }
        ]
      }

      {:ok, merge(%Result{type: {:message, message.full_name}, messages: [message]}, [values])}
    end
  end

  # `message <hint>Item { optional <item> value = 1; }` (empty item = nil)
  defp item_wrapper(inner, constraints, opts) do
    with {:ok, base} <- hint(opts, inner),
         {:ok, value} <-
           to_proto(
             inner,
             constraints,
             opts |> Keyword.put(:allow_nil?, true) |> Keyword.delete(:distinguish_nil?)
           ) do
      name = base <> "Item"

      message = %IR.Message{
        name: name,
        full_name: IR.full_name(opts[:package], name),
        module: module_for(name, opts),
        source: {:item_wrapper, inner, constraints},
        fields: [
          %IR.Field{
            name: "value",
            number: 1,
            type: value.type,
            label: value.label,
            source: {:wrapped, inner, constraints}
          }
        ]
      }

      {:ok, merge(%Result{type: {:message, message.full_name}, messages: [message]}, [value])}
    end
  end

  ## helpers

  defp hint(opts, type) do
    case opts[:name_hint] do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, {:name_hint_required, type}}
    end
  end

  defp nested_opts(opts),
    do: Keyword.take(opts, [:package, :module_prefix, :resolve_resource])

  defp module_for(name, opts) do
    case opts[:module_prefix] do
      nil -> nil
      prefix -> Module.concat(prefix, name)
    end
  end

  defp merge(%Result{} = result, results) do
    Enum.reduce(results, result, fn sub, acc ->
      %{
        acc
        | messages: uniq_by_name(acc.messages ++ sub.messages),
          enums: uniq_by_name(acc.enums ++ sub.enums),
          imports: Enum.uniq(acc.imports ++ sub.imports)
      }
    end)
  end

  defp uniq_by_name(definitions), do: Enum.uniq_by(definitions, & &1.full_name)

  defp duplicates(names) do
    names |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0))
  end

  defp reduce_ok(enumerable, acc, fun) do
    Enum.reduce_while(enumerable, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp finalize(%Result{} = result, opts) do
    result
    |> put_label(Keyword.get(opts, :allow_nil?, true))
    |> put_imports()
  end

  # Scalars need explicit presence to distinguish nil from the default value.
  # Messages always have presence; repeated fields cannot be optional.
  defp put_label(%Result{label: nil, type: type} = result, true) when IR.is_scalar(type),
    do: %{result | label: :optional}

  defp put_label(%Result{label: nil, type: {:enum, _}} = result, true),
    do: %{result | label: :optional}

  defp put_label(result, _), do: result

  defp put_imports(%Result{} = result) do
    imports =
      [result.type | Enum.flat_map(result.messages, fn m -> Enum.map(m.fields, & &1.type) end)]
      |> Enum.flat_map(&type_imports/1)

    %{result | imports: Enum.uniq(result.imports ++ imports)}
  end

  defp type_imports({:message, full_name}), do: List.wrap(Known.import_path(full_name))
  defp type_imports({:map, _, value}), do: type_imports(value)
  defp type_imports(_), do: []
end
