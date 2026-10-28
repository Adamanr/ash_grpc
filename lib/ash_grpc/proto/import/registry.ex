defmodule AshGrpc.Proto.Import.Registry do
  @moduledoc """
  Index of every message, enum and extension in a `FileDescriptorSet`
  (including files that are excluded from the import output), keyed by
  fully-qualified name without the leading dot.
  """

  defstruct messages: %{}, enums: %{}, extensions: %{}, files: %{}

  @type t :: %__MODULE__{
          messages: %{String.t() => Google.Protobuf.DescriptorProto.t()},
          enums: %{String.t() => Google.Protobuf.EnumDescriptorProto.t()},
          extensions: %{
            {String.t(), pos_integer()} => {String.t(), Google.Protobuf.FieldDescriptorProto.t()}
          },
          files: %{String.t() => String.t()}
        }

  alias AshGrpc.Proto.IR

  @doc "Builds the registry. `files` maps each type's full name to its file path."
  @spec build([Google.Protobuf.FileDescriptorProto.t()]) :: t()
  def build(files) do
    Enum.reduce(files, %__MODULE__{}, fn file, registry ->
      scope = file.package

      registry
      |> add_extensions(scope, file.extension)
      |> add_enums(scope, file.enum_type, file.name)
      |> add_messages(scope, file.message_type, file.name)
    end)
  end

  @doc "Strips the leading dot of a descriptor type reference."
  @spec strip(String.t()) :: String.t()
  def strip("." <> name), do: name
  def strip(name), do: name

  @doc "Returns true if the message is a synthetic map entry."
  @spec map_entry?(t(), String.t()) :: boolean()
  def map_entry?(registry, full_name) do
    case registry.messages[full_name] do
      %{options: %{map_entry: true}} -> true
      _ -> false
    end
  end

  defp add_messages(registry, scope, messages, path) do
    Enum.reduce(messages, registry, fn message, registry ->
      full_name = IR.full_name(scope, message.name)

      %{
        registry
        | messages: Map.put(registry.messages, full_name, message),
          files: Map.put(registry.files, full_name, path)
      }
      |> add_extensions(full_name, message.extension)
      |> add_enums(full_name, message.enum_type, path)
      |> add_messages(full_name, message.nested_type, path)
    end)
  end

  defp add_enums(registry, scope, enums, path) do
    Enum.reduce(enums, registry, fn enum, registry ->
      full_name = IR.full_name(scope, enum.name)

      %{
        registry
        | enums: Map.put(registry.enums, full_name, enum),
          files: Map.put(registry.files, full_name, path)
      }
    end)
  end

  defp add_extensions(registry, scope, extensions) do
    Enum.reduce(extensions, registry, fn extension, registry ->
      key = {strip(extension.extendee), extension.number}
      value = {IR.full_name(scope, extension.name), extension}
      %{registry | extensions: Map.put(registry.extensions, key, value)}
    end)
  end
end
