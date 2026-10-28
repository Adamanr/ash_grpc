defmodule AshGrpc.Proto.WellKnown do
  @moduledoc """
  Google well-known types (`google/protobuf/*.proto`) shipped with the `protobuf` library.

  Builders reference them via `{:message, full_name}` and add `import_path/1`
  to the file imports. Renderers never emit their definitions.
  """

  @types %{
    "google.protobuf.Any" => {"google/protobuf/any.proto", Google.Protobuf.Any},
    "google.protobuf.Duration" => {"google/protobuf/duration.proto", Google.Protobuf.Duration},
    "google.protobuf.Empty" => {"google/protobuf/empty.proto", Google.Protobuf.Empty},
    "google.protobuf.FieldMask" =>
      {"google/protobuf/field_mask.proto", Google.Protobuf.FieldMask},
    "google.protobuf.Struct" => {"google/protobuf/struct.proto", Google.Protobuf.Struct},
    "google.protobuf.Value" => {"google/protobuf/struct.proto", Google.Protobuf.Value},
    "google.protobuf.ListValue" => {"google/protobuf/struct.proto", Google.Protobuf.ListValue},
    "google.protobuf.NullValue" => {"google/protobuf/struct.proto", Google.Protobuf.NullValue},
    "google.protobuf.Timestamp" => {"google/protobuf/timestamp.proto", Google.Protobuf.Timestamp},
    "google.protobuf.BoolValue" => {"google/protobuf/wrappers.proto", Google.Protobuf.BoolValue},
    "google.protobuf.BytesValue" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.BytesValue},
    "google.protobuf.DoubleValue" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.DoubleValue},
    "google.protobuf.FloatValue" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.FloatValue},
    "google.protobuf.Int32Value" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.Int32Value},
    "google.protobuf.Int64Value" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.Int64Value},
    "google.protobuf.StringValue" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.StringValue},
    "google.protobuf.UInt32Value" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.UInt32Value},
    "google.protobuf.UInt64Value" =>
      {"google/protobuf/wrappers.proto", Google.Protobuf.UInt64Value}
  }

  @doc "Returns true if the full name is a well-known type."
  @spec well_known?(String.t()) :: boolean()
  def well_known?(full_name), do: Map.has_key?(@types, full_name)

  @doc "Import path of a well-known type."
  @spec import_path(String.t()) :: String.t() | nil
  def import_path(full_name) do
    case Map.fetch(@types, full_name) do
      {:ok, {path, _}} -> path
      :error -> nil
    end
  end

  @doc "Elixir module of a well-known type."
  @spec module(String.t()) :: module() | nil
  def module(full_name) do
    case Map.fetch(@types, full_name) do
      {:ok, {_, module}} -> module
      :error -> nil
    end
  end

  @doc "All well-known type full names."
  @spec all() :: [String.t()]
  def all, do: Map.keys(@types)
end
