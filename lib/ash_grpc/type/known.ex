defmodule AshGrpc.Type.Known do
  @moduledoc """
  Message types AshGrpc maps Ash values to that live outside the user's schema:
  the protobuf well-known types (`AshGrpc.Proto.WellKnown`) plus the
  `google.type.*` messages shipped by the `googleapis` dependency.
  """

  alias AshGrpc.Proto.WellKnown

  @google_types %{
    "google.type.Date" => {"google/type/date.proto", Google.Type.Date},
    "google.type.TimeOfDay" => {"google/type/timeofday.proto", Google.Type.TimeOfDay},
    "google.type.Decimal" => {"google/type/decimal.proto", Google.Type.Decimal}
  }

  @wrappers %{
    "google.protobuf.BoolValue" => :bool,
    "google.protobuf.BytesValue" => :bytes,
    "google.protobuf.DoubleValue" => :double,
    "google.protobuf.FloatValue" => :float,
    "google.protobuf.Int32Value" => :int32,
    "google.protobuf.Int64Value" => :int64,
    "google.protobuf.StringValue" => :string,
    "google.protobuf.UInt32Value" => :uint32,
    "google.protobuf.UInt64Value" => :uint64
  }

  @doc "True when `full_name` is a well-known or supported `google.type.*` message."
  @spec known?(String.t()) :: boolean()
  def known?(full_name),
    do: WellKnown.well_known?(full_name) or Map.has_key?(@google_types, full_name)

  @doc "Import path of a known message, or `nil`."
  @spec import_path(String.t()) :: String.t() | nil
  def import_path(full_name) do
    case Map.fetch(@google_types, full_name) do
      {:ok, {path, _}} -> path
      :error -> WellKnown.import_path(full_name)
    end
  end

  @doc "Elixir module of a known message, or `nil`."
  @spec module(String.t()) :: module() | nil
  def module(full_name) do
    case Map.fetch(@google_types, full_name) do
      {:ok, {_, module}} -> module
      :error -> WellKnown.module(full_name)
    end
  end

  @doc "Scalar wrapped by a `google.protobuf.*Value` wrapper, or `nil`."
  @spec wrapper_scalar(String.t()) :: AshGrpc.Proto.IR.scalar() | nil
  def wrapper_scalar(full_name), do: Map.get(@wrappers, full_name)
end
