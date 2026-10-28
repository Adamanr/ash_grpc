defmodule AshGrpc.Proto.Diff do
  @moduledoc """
  Compares two `AshGrpc.Proto.IR.Schema`s and reports wire/JSON compatibility
  changes (the rules behind `mix ash_grpc.codegen --check`).

  The breaking rules are a subset of buf's `WIRE_JSON` category (DESIGN.md §4.2).
  Messages, enums and services are matched by full name, fields and enum values
  by number.

  | kind | severity |
  |---|---|
  | `:package_changed` (same file path, different package) | breaking |
  | `:field_removed` (number/name not reserved) | breaking |
  | `:field_removed_reserved` (number and name reserved) | safe |
  | `:field_number_changed` (same name, other number) | breaking |
  | `:field_renamed` (same number, other name/JSON name) | breaking |
  | `:field_json_name_changed` | breaking |
  | `:field_type_changed` (incompatible type) | breaking |
  | `:field_type_changed_compatible` (e.g. `int32` → `int64`) | safe |
  | `:field_label_changed` (singular ↔ repeated, `required` changes) | breaking |
  | `:field_presence_changed` (implicit ↔ `optional`) | safe |
  | `:field_oneof_changed` (moved into/out of/between oneofs) | breaking |
  | `:reserved_number_reused` / `:reserved_name_reused` | breaking |
  | `:field_added`, `:message_added`, `:message_removed` | safe |
  | `:enum_value_removed` (not reserved) / `:enum_value_removed_reserved` | breaking / safe |
  | `:enum_value_number_changed`, `:enum_value_renamed` | breaking |
  | `:enum_value_added`, `:enum_added`, `:enum_removed` | safe |
  | `:service_removed`, `:rpc_removed` (incl. renames) | breaking |
  | `:rpc_request_changed`, `:rpc_response_changed`, `:rpc_streaming_changed` | breaking |
  | `:service_added`, `:rpc_added`, `:rpc_idempotency_changed` | safe |

  Removing a message or enum is reported as safe: fields and rpcs that still
  referenced it are reported on their own. Compatible type groups (wire *and*
  JSON): `int32/uint32/int64/uint64`, `sint32/sint64`, `fixed32/sfixed32`,
  `fixed64/sfixed64`.
  """

  alias AshGrpc.Proto.{IR, Lock, Render}

  defmodule Change do
    @moduledoc "A single difference between two schemas."
    defstruct [:kind, :severity, :path, :message]

    @type t :: %__MODULE__{
            kind: atom(),
            severity: :breaking | :safe,
            path: String.t(),
            message: String.t()
          }
  end

  @compatible_groups [
    [:int32, :uint32, :int64, :uint64],
    [:sint32, :sint64],
    [:fixed32, :sfixed32],
    [:fixed64, :sfixed64]
  ]

  @doc """
  Lists the changes from `old` to `new`, sorted by path and kind.
  """
  @spec diff(old :: IR.Schema.t(), new :: IR.Schema.t()) :: [Change.t()]
  def diff(%IR.Schema{} = old, %IR.Schema{} = new) do
    (diff_files(old, new) ++
       diff_named(messages(old), messages(new), &diff_message/2, :message) ++
       diff_named(enums(old), enums(new), &diff_enum/2, :enum) ++
       diff_named(services(old), services(new), &diff_service/2, :service))
    |> Enum.sort_by(&{&1.path, &1.kind})
  end

  @doc "Returns true if any change is breaking."
  @spec breaking?([Change.t()]) :: boolean()
  def breaking?(changes), do: Enum.any?(changes, &(&1.severity == :breaking))

  @doc "Only the breaking changes."
  @spec breaking([Change.t()]) :: [Change.t()]
  def breaking(changes), do: Enum.filter(changes, &(&1.severity == :breaking))

  @doc """
  Human-readable report, one line per change, breaking changes first:

      [breaking] acme.v1.User.email: field "email" (2) was removed without reserving its number and name
      [safe]     acme.v1.User.phone: field "phone" (5) was added
  """
  @spec format([Change.t()]) :: String.t()
  def format([]), do: "No changes."

  def format(changes) do
    {breaking, safe} = Enum.split_with(changes, &(&1.severity == :breaking))
    Enum.map_join(breaking ++ safe, "\n", &format_change/1)
  end

  @doc "Formats a single change."
  @spec format_change(Change.t()) :: String.t()
  def format_change(%Change{severity: :breaking, path: path, message: message}),
    do: "[breaking] #{path}: #{message}"

  def format_change(%Change{severity: :safe, path: path, message: message}),
    do: "[safe]     #{path}: #{message}"

  # -- files --------------------------------------------------------------------------------

  defp diff_files(old, new) do
    new_by_path = Map.new(new.files, &{&1.path, &1})

    for %IR.File{path: path, package: package} <- old.files,
        %IR.File{package: new_package} <- [new_by_path[path]],
        (package || "") != (new_package || "") do
      breaking(
        :package_changed,
        path,
        "package changed from #{inspect(package)} to #{inspect(new_package)}"
      )
    end
  end

  # -- generic matching ---------------------------------------------------------------------

  defp diff_named(old, new, diff_fun, what) do
    removed =
      for {name, _} <- old, not Map.has_key?(new, name), do: removed(what, name)

    added =
      for {name, _} <- new, not Map.has_key?(old, name), do: added(what, name)

    changed =
      for {name, old_node} <- old, new_node = new[name], new_node != nil do
        diff_fun.(old_node, new_node)
      end

    removed ++ added ++ List.flatten(changed)
  end

  defp removed(:message, name),
    do:
      safe(
        :message_removed,
        name,
        "message was removed (referencing fields/rpcs are checked separately)"
      )

  defp removed(:enum, name),
    do: safe(:enum_removed, name, "enum was removed (referencing fields are checked separately)")

  defp removed(:service, name), do: breaking(:service_removed, name, "service was removed")

  defp added(:message, name), do: safe(:message_added, name, "message was added")
  defp added(:enum, name), do: safe(:enum_added, name, "enum was added")
  defp added(:service, name), do: safe(:service_added, name, "service was added")

  # -- messages -----------------------------------------------------------------------------

  defp diff_message(%IR.Message{} = old, %IR.Message{} = new) do
    old_by_number = Map.new(old.fields, &{&1.number, &1})
    new_by_number = Map.new(new.fields, &{&1.number, &1})
    new_by_name = Map.new(new.fields, &{&1.name, &1})

    removed_or_moved =
      for %IR.Field{number: number} = field <- old.fields,
          not Map.has_key?(new_by_number, number) do
        path = new.full_name <> "." <> field.name

        case new_by_name[field.name] do
          %IR.Field{number: new_number} ->
            breaking(
              :field_number_changed,
              path,
              "field #{inspect(field.name)} changed number from #{number} to #{new_number}"
            )

          nil ->
            removed_field(field, new, path)
        end
      end

    added =
      for %IR.Field{number: number} = field <- new.fields,
          not Map.has_key?(old_by_number, number),
          # a field that only changed its number is reported as :field_number_changed
          not Enum.any?(old.fields, &(&1.name == field.name)) do
        added_field(field, old, new.full_name <> "." <> field.name)
      end

    changed =
      for %IR.Field{number: number} = old_field <- old.fields,
          new_field = new_by_number[number],
          new_field != nil do
        diff_field(old_field, new_field, new)
      end

    List.flatten([removed_or_moved, added, changed])
  end

  defp added_field(%IR.Field{name: name, number: number}, old, path) do
    cond do
      Lock.reserved?(number, old.reserved_numbers) ->
        breaking(
          :reserved_number_reused,
          path,
          "field #{inspect(name)} reuses reserved number #{number}"
        )

      name in old.reserved_names ->
        breaking(:reserved_name_reused, path, "field #{inspect(name)} reuses a reserved name")

      true ->
        safe(:field_added, path, "field #{inspect(name)} (#{number}) was added")
    end
  end

  defp removed_field(field, new, path) do
    number_reserved? = Lock.reserved?(field.number, new.reserved_numbers)
    name_reserved? = field.name in new.reserved_names

    if number_reserved? and name_reserved? do
      safe(
        :field_removed_reserved,
        path,
        "field #{inspect(field.name)} (#{field.number}) was removed and reserved"
      )
    else
      missing =
        [{number_reserved?, "number"}, {name_reserved?, "name"}]
        |> Enum.reject(&elem(&1, 0))
        |> Enum.map_join(" and ", &elem(&1, 1))

      breaking(
        :field_removed,
        path,
        "field #{inspect(field.name)} (#{field.number}) was removed without reserving its #{missing}"
      )
    end
  end

  defp diff_field(%IR.Field{} = old, %IR.Field{} = new, new_message) do
    path = new_message.full_name <> "." <> new.name

    [
      if old.name != new.name do
        breaking(
          :field_renamed,
          path,
          "field #{old.number} was renamed from #{inspect(old.name)} to #{inspect(new.name)} " <>
            "(breaks JSON and the field name)"
        )
      end,
      if old.name == new.name and json_name(old) != json_name(new) do
        breaking(
          :field_json_name_changed,
          path,
          "json_name changed from #{inspect(json_name(old))} to #{inspect(json_name(new))}"
        )
      end,
      diff_type(old.type, new.type, path),
      diff_label(effective_label(old), effective_label(new), path),
      diff_oneof(old.oneof, new.oneof, path)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp diff_type(type, type, _path), do: nil

  defp diff_type(old, new, path) do
    if compatible_type?(old, new) do
      safe(
        :field_type_changed_compatible,
        path,
        "type changed from #{type_name(old)} to #{type_name(new)} (wire compatible)"
      )
    else
      breaking(
        :field_type_changed,
        path,
        "type changed from #{type_name(old)} to #{type_name(new)}"
      )
    end
  end

  defp compatible_type?(old, new) when is_atom(old) and is_atom(new),
    do: Enum.any?(@compatible_groups, &(old in &1 and new in &1))

  defp compatible_type?({:map, key, old_value}, {:map, key, new_value}),
    do: compatible_type?(old_value, new_value)

  defp compatible_type?(_old, _new), do: false

  # maps are repeated on the wire; the label of a map field is irrelevant
  defp effective_label(%IR.Field{type: {:map, _, _}}), do: :repeated
  defp effective_label(%IR.Field{label: label}), do: label

  defp diff_label(label, label, _path), do: nil

  defp diff_label(old, new, path) when old in [nil, :optional] and new in [nil, :optional] do
    safe(
      :field_presence_changed,
      path,
      "presence changed from #{label_name(old)} to #{label_name(new)}"
    )
  end

  defp diff_label(old, new, path) do
    breaking(
      :field_label_changed,
      path,
      "label changed from #{label_name(old)} to #{label_name(new)}"
    )
  end

  defp diff_oneof(oneof, oneof, _path), do: nil

  defp diff_oneof(old, new, path),
    do:
      breaking(
        :field_oneof_changed,
        path,
        "oneof changed from #{oneof_name(old)} to #{oneof_name(new)}"
      )

  # -- enums --------------------------------------------------------------------------------

  defp diff_enum(%IR.Enum{} = old, %IR.Enum{} = new) do
    old_by_name = Map.new(old.values, &{&1.name, &1})
    new_by_name = Map.new(new.values, &{&1.name, &1})
    new_numbers = MapSet.new(new.values, & &1.number)

    removed_or_changed =
      for %IR.EnumValue{name: name, number: number} <- old.values do
        path = new.full_name <> "." <> name

        case new_by_name[name] do
          %IR.EnumValue{number: ^number} ->
            []

          %IR.EnumValue{number: new_number} ->
            breaking(
              :enum_value_number_changed,
              path,
              "enum value #{name} changed number from #{number} to #{new_number}"
            )

          nil ->
            removed_enum_value(name, number, new, new_numbers, path)
        end
      end

    added =
      for %IR.EnumValue{name: name, number: number} <- new.values,
          not Map.has_key?(old_by_name, name) do
        path = new.full_name <> "." <> name

        cond do
          Lock.reserved?(number, old.reserved_numbers) ->
            breaking(
              :reserved_number_reused,
              path,
              "enum value #{name} reuses reserved number #{number}"
            )

          name in old.reserved_names ->
            breaking(:reserved_name_reused, path, "enum value #{name} reuses a reserved name")

          true ->
            safe(:enum_value_added, path, "enum value #{name} (#{number}) was added")
        end
      end

    List.flatten([removed_or_changed, added])
  end

  defp removed_enum_value(name, number, new, new_numbers, path) do
    cond do
      MapSet.member?(new_numbers, number) ->
        others =
          new.values |> Enum.filter(&(&1.number == number)) |> Enum.map_join(", ", & &1.name)

        breaking(
          :enum_value_renamed,
          path,
          "enum value #{name} (#{number}) was renamed to #{others} (breaks JSON, which uses names)"
        )

      Lock.reserved?(number, new.reserved_numbers) and name in new.reserved_names ->
        safe(
          :enum_value_removed_reserved,
          path,
          "enum value #{name} (#{number}) was removed and reserved"
        )

      true ->
        breaking(
          :enum_value_removed,
          path,
          "enum value #{name} (#{number}) was removed without reserving its number and name"
        )
    end
  end

  # -- services -----------------------------------------------------------------------------

  defp diff_service(%IR.Service{} = old, %IR.Service{} = new) do
    new_by_name = Map.new(new.rpcs, &{&1.name, &1})
    old_names = MapSet.new(old.rpcs, & &1.name)

    removed_or_changed =
      for %IR.Rpc{name: name} = old_rpc <- old.rpcs do
        path = new.full_name <> "." <> name

        case new_by_name[name] do
          nil -> breaking(:rpc_removed, path, "rpc #{name} was removed or renamed")
          new_rpc -> diff_rpc(old_rpc, new_rpc, path)
        end
      end

    added =
      for %IR.Rpc{name: name} <- new.rpcs, not MapSet.member?(old_names, name) do
        safe(:rpc_added, new.full_name <> "." <> name, "rpc #{name} was added")
      end

    List.flatten([removed_or_changed, added])
  end

  defp diff_rpc(%IR.Rpc{} = old, %IR.Rpc{} = new, path) do
    [
      if old.input != new.input do
        breaking(
          :rpc_request_changed,
          path,
          "request type changed from #{old.input} to #{new.input}"
        )
      end,
      if old.output != new.output do
        breaking(
          :rpc_response_changed,
          path,
          "response type changed from #{old.output} to #{new.output}"
        )
      end,
      if {old.client_streaming?, old.server_streaming?} !=
           {new.client_streaming?, new.server_streaming?} do
        breaking(
          :rpc_streaming_changed,
          path,
          "streaming changed from #{streaming(old)} to #{streaming(new)}"
        )
      end,
      if old.idempotency_level != new.idempotency_level do
        safe(
          :rpc_idempotency_changed,
          path,
          "idempotency_level changed from #{inspect(old.idempotency_level)} to #{inspect(new.idempotency_level)}"
        )
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp streaming(%IR.Rpc{client_streaming?: false, server_streaming?: false}), do: "unary"

  defp streaming(%IR.Rpc{client_streaming?: true, server_streaming?: false}),
    do: "client streaming"

  defp streaming(%IR.Rpc{client_streaming?: false, server_streaming?: true}),
    do: "server streaming"

  defp streaming(%IR.Rpc{}), do: "bidirectional streaming"

  # -- indexes ------------------------------------------------------------------------------

  defp messages(%IR.Schema{files: files}) do
    files
    |> Enum.flat_map(&flatten_messages(&1.messages))
    |> Map.new(&{&1.full_name, &1})
  end

  defp flatten_messages(messages),
    do: Enum.flat_map(messages, &[&1 | flatten_messages(&1.nested_messages)])

  defp enums(%IR.Schema{files: files}) do
    files
    |> Enum.flat_map(fn file ->
      file.enums ++ Enum.flat_map(flatten_messages(file.messages), & &1.nested_enums)
    end)
    |> Map.new(&{&1.full_name, &1})
  end

  defp services(%IR.Schema{files: files}) do
    files
    |> Enum.flat_map(& &1.services)
    |> Map.new(&{&1.full_name, &1})
  end

  # -- helpers ------------------------------------------------------------------------------

  defp json_name(%IR.Field{json_name: nil, name: name}), do: Render.default_json_name(name)
  defp json_name(%IR.Field{json_name: json_name}), do: json_name

  defp type_name({:map, key, value}), do: "map<#{key}, #{type_name(value)}>"
  defp type_name({_kind, name}), do: name
  defp type_name(scalar), do: Atom.to_string(scalar)

  defp label_name(nil), do: "implicit presence"
  defp label_name(:optional), do: "optional"
  defp label_name(:repeated), do: "repeated"
  defp label_name(:required), do: "required"

  defp oneof_name(nil), do: "none"
  defp oneof_name(name), do: inspect(name)

  defp breaking(kind, path, message),
    do: %Change{kind: kind, severity: :breaking, path: path, message: message}

  defp safe(kind, path, message),
    do: %Change{kind: kind, severity: :safe, path: path, message: message}
end
