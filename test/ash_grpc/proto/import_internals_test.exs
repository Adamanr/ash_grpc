defmodule AshGrpc.Proto.ImportInternalsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AshGrpc.Proto.Import.{Comments, Naming, Wire}

  describe "Naming" do
    test "protoc-gen-elixir module names" do
      assert Naming.module("billing.v1", ["Invoice", "Item"]) == Billing.V1.Invoice.Item
      assert Naming.module(nil, ["snake_case_msg"]) == SnakeCaseMsg
      assert Naming.module("a.b", ["C"], module_prefix: "Foo.Bar") == Foo.Bar.C
      assert Naming.module("a.b", ["C"], module_prefix: Foo.Bar) == Foo.Bar.C
      assert Naming.module("a.b", ["C"], package_prefix: "pre") == Pre.A.B.C
      assert Naming.service_module("a.v1", "Svc") == A.V1.Svc.Service
    end

    test "invalid identifiers raise" do
      assert_raise ArgumentError, fn -> Naming.module("a", ["B.C; System.halt"]) end
      assert_raise ArgumentError, fn -> Naming.module("a-b", ["C"]) end
    end

    test "external modules" do
      assert Naming.external_module("google.protobuf.Empty") == Google.Protobuf.Empty
      assert Naming.external_module("google.type.LatLng") == Google.Type.LatLng
    end

    test "default json names" do
      assert Naming.default_json_name("customer_email") == "customerEmail"
      assert Naming.default_json_name("a__b") == "aB"
      assert Naming.default_json_name("_leading") == "Leading"
      assert Naming.default_json_name("already") == "already"
    end
  end

  describe "Wire" do
    test "parses all wire types" do
      binary =
        IO.iodata_to_binary([
          Protobuf.Wire.Varint.encode(1 <<< 3 ||| 0),
          Protobuf.Wire.Varint.encode(300),
          <<2 <<< 3 ||| 1, 1, 2, 3, 4, 5, 6, 7, 8>>,
          <<3 <<< 3 ||| 2, 3, "abc">>,
          <<4 <<< 3 ||| 5, 9, 9, 9, 9>>
        ])

      assert {:ok,
              [
                {1, 0, 300},
                {2, 1, <<1, 2, 3, 4, 5, 6, 7, 8>>},
                {3, 2, "abc"},
                {4, 5, <<9, 9, 9, 9>>}
              ]} = Wire.parse(binary)
    end

    test "unpacks packed values and rejects truncated input" do
      assert {:ok, [1, 300]} = Wire.unpack(<<1, 172, 2>>, 0)
      assert :error = Wire.parse(<<3 <<< 3 ||| 2, 10, "short">>)
      assert :error = Wire.parse(<<1 <<< 3 ||| 4>>)
    end
  end

  describe "Comments" do
    test "normalizes indentation and joins leading and trailing comments" do
      file = %Google.Protobuf.FileDescriptorProto{
        source_code_info: %Google.Protobuf.SourceCodeInfo{
          location: [
            %Google.Protobuf.SourceCodeInfo.Location{
              path: [4, 0],
              leading_comments: " First line.\n   indented\n",
              trailing_comments: " trailing\n",
              leading_detached_comments: [" detached\n"]
            },
            %Google.Protobuf.SourceCodeInfo.Location{
              path: [4, 1],
              leading_detached_comments: [" only detached\n"]
            }
          ]
        }
      }

      index = Comments.index(file)
      assert Comments.get(index, [4, 0]) == "First line.\n  indented\n\ntrailing"
      assert Comments.get(index, [4, 1]) == nil
      assert Comments.index(%Google.Protobuf.FileDescriptorProto{}) == %{}
    end
  end
end
