defmodule AshGrpc.Proto.ImportTaskTest do
  # mutates application env (:proto_compiler) and the Mix shell
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AshGrpc.Import, as: ImportTask

  @root "test/fixtures/protos"

  defmodule FakeCompiler do
    @moduledoc false
    def to_source(schema, opts) do
      Enum.map(schema.files, fn file ->
        {String.replace_suffix(file.path, ".proto", ".pb.ex"),
         "# #{file.path} #{inspect(opts)}\n"}
      end)
    end

    def compile(schema, _opts) do
      send(self(), {:compiled, Enum.map(schema.files, & &1.path)})
      []
    end
  end

  setup do
    previous = Application.get_env(:ash_grpc, :proto_compiler)
    Application.put_env(:ash_grpc, :proto_compiler, FakeCompiler)
    Mix.shell(Mix.Shell.Process)

    out =
      Path.join(System.tmp_dir!(), "ash_grpc_import_task_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_grpc, :proto_compiler, previous),
        else: Application.delete_env(:ash_grpc, :proto_compiler)

      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(out)
    end)

    %{out: out}
  end

  defp args(out, extra \\ []) do
    ["#{@root}/acme/billing/**/*.proto", "-I", @root, "--include", "#{@root}/third_party"] ++
      ["--out", out] ++ extra
  end

  describe "mix ash_grpc.import" do
    test "writes one file per imported proto file", %{out: out} do
      ImportTask.run(args(out, ["--module-prefix", "MyApp.Proto"]))

      assert out
             |> Path.join("**/*.pb.ex")
             |> Path.wildcard()
             |> Enum.map(&Path.relative_to(&1, out))
             |> Enum.sort() ==
               [
                 "acme/billing/v1/billing.pb.ex",
                 "acme/common/v1/money.pb.ex",
                 "acme/options/v1/options.pb.ex"
               ]

      assert File.read!(Path.join(out, "acme/billing/v1/billing.pb.ex")) ==
               ~s(# acme/billing/v1/billing.proto [module_prefix: "MyApp.Proto"]\n)

      assert_received {:mix_shell, :info, [_ | _]}
    end

    test "--check passes when up to date and fails when stale", %{out: out} do
      ImportTask.run(args(out))
      ImportTask.run(args(out, ["--check"]))
      assert_received {:mix_shell, :info, ["Imported protobuf modules are up to date."]}

      File.write!(Path.join(out, "acme/common/v1/money.pb.ex"), "changed")

      error = assert_raise Mix.Error, fn -> ImportTask.run(args(out, ["--check"])) end
      assert error.message =~ "acme/common/v1/money.pb.ex"
      refute error.message =~ "billing.pb.ex"
      assert File.read!(Path.join(out, "acme/common/v1/money.pb.ex")) == "changed"
    end

    test "--check fails when files are missing", %{out: out} do
      assert_raise Mix.Error, ~r/out of date/, fn -> ImportTask.run(args(out, ["--check"])) end
      refute File.exists?(out)
    end

    test "defaults include paths to the input directories", %{out: out} do
      ImportTask.run(["#{@root}/nopackage.proto", "--out", out])
      assert File.exists?(Path.join(out, "nopackage.pb.ex"))
    end

    test "usage and input errors", %{out: out} do
      assert_raise Mix.Error, ~r/Usage/, fn -> ImportTask.run([]) end

      assert_raise Mix.Error, ~r/No .proto files match/, fn ->
        ImportTask.run(["nope/*.proto"])
      end

      assert_raise Mix.Error, ~r/protoc exited/, fn ->
        ImportTask.run(["#{@root}/acme/billing/v1/billing.proto", "-I", @root, "--out", out])
      end

      assert_raise Mix.Error, ~r/protoc executable not found at/, fn ->
        ImportTask.run(args(out, ["--protoc", "/nonexistent/protoc"]))
      end

      assert_raise Mix.Error, ~r/proto2 groups are not supported/, fn ->
        ImportTask.run(["#{@root}/unsupported/groups.proto", "-I", @root, "--out", out])
      end
    end

    test "formats errors" do
      assert ImportTask.format_error(:protoc_not_found) =~ "not found in PATH"
      assert ImportTask.format_error({:unresolved_types, ["a.B"]}) =~ "a.B"

      assert ImportTask.format_error({:module_conflict, %{X.Y => ["a.Y", "b.Y"]}}) ==
               "several proto entities map to the same module: X.Y <- a.Y, b.Y"

      assert ImportTask.format_error(:other) == ":other"
    end
  end

  describe "use AshGrpc.Protos" do
    test "imports at compile time and exposes the schema" do
      [{module, _}] =
        Code.compile_string("""
        defmodule AshGrpc.Proto.ImportTaskTest.Billing do
          use AshGrpc.Protos,
            files: ["#{@root}/acme/billing/v1/*.proto"],
            include: ["#{@root}", "#{@root}/third_party"],
            module_prefix: AshGrpc.Proto.ImportTaskTest.Pb
        end
        """)

      assert_received {:compiled,
                       [
                         "acme/common/v1/money.proto",
                         "acme/options/v1/options.proto",
                         "acme/billing/v1/billing.proto"
                       ]}

      assert {:ok, invoice} =
               AshGrpc.Proto.IR.Schema.lookup(module.__schema__(), "acme.billing.v1.Invoice")

      assert invoice.module == AshGrpc.Proto.ImportTaskTest.Pb.Invoice
      assert module.__modules__() == []
    end

    test "raises a compile error when the import fails" do
      assert_raise CompileError, ~r/proto2 groups are not supported/, fn ->
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshGrpc.Proto.ImportTaskTest.Broken do
            use AshGrpc.Protos, files: ["#{@root}/unsupported/groups.proto"]
          end
          """)
        end)
      end

      assert_raise ArgumentError, ~r/requires :files/, fn -> AshGrpc.Protos.resolve!([]) end

      assert_raise ArgumentError, ~r/no files match/, fn ->
        AshGrpc.Protos.resolve!(files: ["nope.proto"])
      end
    end

    test "every input and imported file is an external resource" do
      {files, includes, opts} =
        AshGrpc.Protos.resolve!(
          files: "#{@root}/acme/billing/v1/billing.proto",
          include: [@root, "#{@root}/third_party"],
          module_prefix: Foo,
          other: :ignored
        )

      assert opts == [module_prefix: Foo]
      {:ok, schema} = AshGrpc.Proto.Import.from_files(files, include_paths: includes)

      resources = AshGrpc.Protos.external_resources(files, schema, includes)

      assert Enum.map(resources, &Path.relative_to_cwd/1) == [
               "#{@root}/acme/billing/v1/billing.proto",
               "#{@root}/acme/common/v1/money.proto",
               "#{@root}/acme/options/v1/options.proto"
             ]

      assert {[_], [dir], []} = AshGrpc.Protos.resolve!(files: ["#{@root}/nopackage.proto"])
      assert dir == @root
    end
  end
end
