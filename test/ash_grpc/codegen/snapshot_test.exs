defmodule AshGrpc.Codegen.SnapshotTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Codegen.Snapshot
  alias AshGrpc.Proto.{Diff, IR, Render}
  alias AshGrpc.Test.ProtoFixtures

  setup_all do
    {:ok, schema} = AshGrpc.Schema.build([AshGrpc.Test.Accounts, AshGrpc.Test.Catalog])
    %{schema: schema}
  end

  defp roundtrip(file, domain \\ nil) do
    {:ok, %{file: decoded, domain: decoded_domain}} =
      file |> Snapshot.encode(domain) |> Snapshot.decode()

    {decoded, decoded_domain}
  end

  test "built schemas survive encode → decode without wire or rendering differences", %{
    schema: schema
  } do
    for file <- schema.files do
      {decoded, domain} = roundtrip(file, AshGrpc.Test.Accounts)

      assert domain == "AshGrpc.Test.Accounts"
      assert Diff.diff(%IR.Schema{files: [file]}, %IR.Schema{files: [decoded]}) == []

      assert IO.iodata_to_binary(Render.render(decoded)) ==
               IO.iodata_to_binary(Render.render(file))

      assert Snapshot.encode(decoded) == Snapshot.encode(file)
    end
  end

  test "hand-built IR with options, oneofs, maps, nested types and reserved ranges roundtrips" do
    for file <- [ProtoFixtures.shop_file(), ProtoFixtures.legacy_file()] do
      {decoded, nil} = roundtrip(file)

      assert IO.iodata_to_binary(Render.render(decoded)) ==
               IO.iodata_to_binary(Render.render(file))

      assert Snapshot.encode(decoded) == Snapshot.encode(file)
    end
  end

  test "option values of every shape roundtrip" do
    values = ["s", 1, -2.5, true, :SPEED, :inf, [1, 2], %{"a" => 1, b: [:X]}]

    file = %IR.File{
      path: "a/v1/a.proto",
      package: "a.v1",
      options: Enum.map(values, &%IR.Option{name: "(my.opt)", value: &1}),
      syntax: {:edition, "2023"}
    }

    {decoded, _} = roundtrip(file)
    assert Enum.map(decoded.options, & &1.value) == values
    assert decoded.syntax == {:edition, "2023"}
  end

  test "encoding is deterministic and omits empty values" do
    file = %IR.File{path: "a/v1/a.proto", package: "a.v1"}
    json = Snapshot.encode(file)

    assert json == Snapshot.encode(file)
    assert String.ends_with?(json, "\n")
    refute json =~ "messages"
    refute json =~ "null"
  end

  test "rejects foreign JSON, unknown versions and malformed snapshots" do
    assert {:error, :not_a_snapshot} = Snapshot.decode(~s({"version": 1}))

    assert {:error, {:unsupported_version, 2}} =
             Snapshot.decode(~s({"version": 2, "generator": "ash_grpc"}))

    assert {:error, {:invalid_json, _}} = Snapshot.decode("{")

    assert {:error, {:invalid_snapshot, _}} =
             Snapshot.decode(
               ~s({"version": 1, "generator": "ash_grpc", "file": {"path": "a.proto", "messages": [{"name": "A", "full_name": "A", "fields": [{"name": "x", "number": 1, "type": "int128"}]}]}})
             )

    refute Snapshot.snapshot?(~s({"version": 1}))
    refute Snapshot.snapshot?("not json")
  end

  @tag :tmp_dir
  test "load_dir/1 reads snapshots recursively and skips other JSON files", %{tmp_dir: dir} do
    file = %IR.File{path: "a/v1/a.proto", package: "a.v1"}
    path = Snapshot.path(dir, file.path)
    assert path == Path.join(dir, "a/v1/a.json")

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Snapshot.encode(file, "MyApp.A"))
    File.write!(Path.join(dir, "other.json"), ~s({"x": 1}))

    assert {:ok, [{^path, %{domain: "MyApp.A", file: %IR.File{package: "a.v1"}}}]} =
             Snapshot.load_dir(dir)

    assert {:ok, []} = Snapshot.load_dir(Path.join(dir, "missing"))

    File.write!(path, ~s({"version": 9, "generator": "ash_grpc"}))
    assert {:error, {:snapshot, ^path, {:unsupported_version, 9}}} = Snapshot.load_dir(dir)
  end
end
