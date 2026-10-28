defmodule AshGrpc.Type.MappingTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Type.Mapping
  alias AshGrpc.Type.Mapping.Result

  test "nullable scalars get explicit presence" do
    assert {:ok, %Result{type: :string, label: :optional}} = Mapping.to_proto(:string)

    assert {:ok, %Result{type: :int64, label: nil}} =
             Mapping.to_proto(:integer, [], allow_nil?: false)
  end

  test "arrays are repeated" do
    assert {:ok, %Result{type: :string, label: :repeated}} = Mapping.to_proto({:array, :string})
  end

  test "datetimes map to Timestamp and add the import" do
    assert {:ok,
            %Result{
              type: {:message, "google.protobuf.Timestamp"},
              imports: ["google/protobuf/timestamp.proto"]
            }} =
             Mapping.to_proto(:utc_datetime_usec)
  end
end
