defmodule AshGrpc.CodegenTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Codegen
  alias AshGrpc.Codegen.Plan
  alias AshGrpc.Proto.{IR, Lock}
  alias AshGrpc.Test.Codegen.{Gadgets, Widgets}
  alias AshGrpc.Test.Protoc

  @moduletag :tmp_dir

  @widgets_proto "ashgrpc/test/widgets/v1/widgets.proto"
  @gadgets_proto "ashgrpc/test/gadgets/v1/gadgets.proto"

  setup %{tmp_dir: dir} do
    opts = [
      out: Path.join(dir, "priv/protos"),
      lock: Path.join(dir, "priv/grpc/ash_grpc.lock.json"),
      snapshots: Path.join(dir, "priv/grpc/snapshots")
    ]

    %{opts: opts, dir: dir}
  end

  defp plan!(domains, opts, extra \\ []) do
    {:ok, plan} = Codegen.plan([domains: List.wrap(domains)] ++ extra ++ opts)
    plan
  end

  defp generate!(domains, opts, extra \\ []) do
    plan = plan!(domains, opts, extra)
    :ok = Codegen.write!(plan)
    plan
  end

  defp proto(opts, path \\ @widgets_proto), do: File.read!(Path.join(opts[:out], path))

  defp widget(plan) do
    {:ok, message} = IR.Schema.lookup(plan.schema, "ashgrpc.test.widgets.v1.Widget")
    message
  end

  defp numbers(message), do: Map.new(message.fields, &{&1.name, &1.number})

  defp tree(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, dir), File.read!(&1)})
  end

  test "fresh generation writes protos with the header, snapshots and the lock", %{opts: opts} do
    plan = generate!(Widgets.V1, opts)

    assert Enum.map(plan.files, &{&1.kind, &1.status}) == [
             proto: :created,
             snapshot: :created,
             lock: :created
           ]

    assert Codegen.generated?(proto(opts))
    assert proto(opts) =~ "// source: AshGrpc.Test.Codegen.Widgets.V1\n"
    assert proto(opts) =~ "package ashgrpc.test.widgets.v1;"
    assert File.exists?(Path.join(opts[:snapshots], "ashgrpc/test/widgets/v1/widgets.json"))

    assert {:ok, lock} = Lock.load(opts[:lock])
    assert lock.messages["ashgrpc.test.widgets.v1.Widget"].fields == numbers(widget(plan))

    # every change of a fresh generation is an addition
    assert plan.changes != []
    refute Plan.breaking?(plan)
  end

  test "a second run is a no-op", %{opts: opts, dir: dir} do
    generate!(Widgets.V1, opts)
    before = tree(dir)

    plan = plan!(Widgets.V1, opts)
    refute Plan.changed?(plan)
    assert plan.changes == []
    assert Plan.summary(plan) == []

    :ok = Codegen.write!(plan)
    assert tree(dir) == before
  end

  test "adding a field keeps the existing numbers", %{opts: opts} do
    v1 = generate!(Widgets.V1, opts)
    v2 = generate!(Widgets.V2, opts)

    old = numbers(widget(v1))
    new = numbers(widget(v2))

    assert Map.take(new, Map.keys(old)) == old
    assert new["color"] == Enum.max(Map.values(old)) + 1

    assert Enum.any?(v2.changes, &(&1.kind == :field_added and &1.path =~ "Widget.color"))
    refute Plan.breaking?(v2)
    assert Enum.map(Plan.pending_files(v2), & &1.kind) == [:proto, :snapshot, :lock]
  end

  test "removing a field reserves its number and name", %{opts: opts} do
    v1 = generate!(Widgets.V1, opts)
    v3 = generate!(Widgets.V3, opts)

    size = numbers(widget(v1))["size"]
    message = widget(v3)

    assert size in message.reserved_numbers
    assert "size" in message.reserved_names
    assert proto(opts) =~ ~r/reserved #{size};/
    assert proto(opts) =~ ~s(reserved "size";)

    assert Enum.any?(v3.changes, &(&1.kind == :field_removed_reserved))
    refute Plan.breaking?(v3)

    # the reservation survives in the lock: re-adding `size` is rejected
    assert {:error, [%Lock.ConflictError{} = error]} =
             Codegen.plan([domains: [Widgets.V1]] ++ opts)

    assert Codegen.format_error([error]) =~ "Widget.size: name is reserved"
  end

  test "an incompatible type change is breaking", %{opts: opts} do
    generate!(Widgets.V1, opts)
    plan = plan!(Widgets.V4, opts)

    assert Plan.breaking?(plan)
    assert Enum.any?(plan.changes, &(&1.kind == :field_type_changed and &1.path =~ "Widget.size"))
  end

  test "lock, snapshots and output are deterministic", %{tmp_dir: dir} do
    run = fn sub ->
      root = Path.join(dir, sub)

      generate!(
        [Widgets.V2, Gadgets],
        [
          out: Path.join(root, "protos"),
          lock: Path.join(root, "lock.json"),
          snapshots: Path.join(root, "snapshots")
        ],
        buf: true
      )

      tree(root)
    end

    first = run.("a")
    assert map_size(first) == 6
    assert first == run.("b")
  end

  test "stale generated protos are deleted, hand-written ones are kept", %{opts: opts} do
    generate!([Widgets.V1, Gadgets], opts)

    hand_written = Path.join(opts[:out], "acme/v1/manual.proto")
    File.mkdir_p!(Path.dirname(hand_written))
    File.write!(hand_written, ~s(syntax = "proto3";\npackage acme.v1;\n))

    plan = generate!(Widgets.V1, opts)

    assert Enum.sort(Enum.map(plan.deletes, &{&1.kind, Path.basename(&1.path)})) == [
             proto: "gadgets.proto",
             snapshot: "gadgets.json"
           ]

    refute File.exists?(Path.join(opts[:out], @gadgets_proto))
    assert File.exists?(hand_written)
    assert Enum.any?(plan.changes, &(&1.kind == :service_removed))
  end

  test "a domain subset leaves the files of other domains alone", %{opts: opts} do
    generate!([Widgets.V1, Gadgets], opts)

    plan = plan!(Widgets.V2, opts, all_domains?: false)

    assert plan.deletes == []
    refute Enum.any?(plan.changes, &(&1.kind in [:service_removed, :message_removed]))
    assert File.exists?(Path.join(opts[:out], @gadgets_proto))
  end

  test "buf: true writes buf.yaml", %{opts: opts} do
    generate!(Widgets.V1, opts, buf: true)
    buf_yaml = File.read!(Path.join(opts[:out], "buf.yaml"))

    assert buf_yaml =~ "version: v2"
    assert buf_yaml =~ "# " <> Codegen.header()
    refute buf_yaml =~ "googleapis"

    googleapis = %IR.Schema{
      files: [%IR.File{path: "a.proto", imports: ["google/type/date.proto"]}]
    }

    assert Codegen.buf_yaml(googleapis) =~ "buf.build/googleapis/googleapis"
  end

  test "lock conflicts and broken snapshots are errors", %{opts: opts} do
    File.mkdir_p!(Path.dirname(opts[:lock]))
    File.write!(opts[:lock], "{")

    assert {:error, {:lock, _, {:invalid_json, _}} = error} =
             Codegen.plan([domains: [Gadgets]] ++ opts)

    assert Codegen.format_error(error) =~ "cannot load lock"

    File.rm!(opts[:lock])
    broken = Path.join(opts[:snapshots], "x.json")
    File.mkdir_p!(opts[:snapshots])
    File.write!(broken, ~s({"version": 7, "generator": "ash_grpc"}))
    assert {:error, {:snapshot, ^broken, _} = error} = Codegen.plan([domains: [Gadgets]] ++ opts)
    assert Codegen.format_error(error) =~ "cannot load snapshot"
  end

  describe "protoc" do
    @describetag :protoc

    test "rendered output is accepted by protoc", %{opts: opts} do
      if Protoc.available?() do
        generate!([Widgets.V2, Gadgets], opts)

        set = Protoc.descriptor_set!(opts[:out], [@widgets_proto, @gadgets_proto])
        names = Enum.map(set.file, & &1.name)

        assert @widgets_proto in names
        assert @gadgets_proto in names
      end
    end

    test "buf lint and buf build accept the output", %{opts: opts} do
      if Protoc.buf_available?() do
        generate!([Widgets.V3, Gadgets], opts, buf: true)

        for args <- [["lint"], ["build"]] do
          assert {output, 0} = System.cmd("buf", args, cd: opts[:out], stderr_to_stdout: true)
          assert output == ""
        end
      end
    end
  end
end
