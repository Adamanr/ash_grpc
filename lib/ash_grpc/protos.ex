defmodule AshGrpc.Protos do
  @moduledoc """
  Imports foreign `.proto` files at compile time, without generated files in git.

      defmodule MyApp.Proto.Billing do
        use AshGrpc.Protos,
          files: ["priv/protos/billing/v1/billing.proto"],
          include: ["priv/protos"],
          module_prefix: MyApp.Proto
      end

  The protobuf/gRPC modules are compiled by `AshGrpc.Proto.Compiler.compile/2`
  when the using module compiles. Every input file and every imported file
  that lives inside an include path is an `@external_resource`, so editing a
  `.proto` recompiles the module. Requires `protoc` at compile time.

  ## Options

    * `:files` (required) – `.proto` files or glob patterns, relative to the
      project root (`File.cwd!/0` at compile time)
    * `:include` – import paths (default: the directories of the files)
    * `:module_prefix`, `:package_prefix`, `:exclude`, `:protoc` – see
      `AshGrpc.Proto.Import.from_files/2`

  The using module gets:

    * `__schema__/0` – the imported `AshGrpc.Proto.IR.Schema`
    * `__modules__/0` – the compiled modules
  """

  defmacro __using__(opts) do
    opts = eval_opts(opts, __CALLER__)
    {files, include_paths, import_opts} = AshGrpc.Protos.resolve!(opts)

    schema =
      case AshGrpc.Proto.Import.from_files(files, [include_paths: include_paths] ++ import_opts) do
        {:ok, schema} ->
          schema

        {:error, reason} ->
          raise CompileError,
            file: __CALLER__.file,
            line: __CALLER__.line,
            description:
              "AshGrpc.Protos import failed: " <> Mix.Tasks.AshGrpc.Import.format_error(reason)
      end

    resources = AshGrpc.Protos.external_resources(files, schema, include_paths)
    compiler = Application.get_env(:ash_grpc, :proto_compiler, AshGrpc.Proto.Compiler)
    modules = compiler.compile(schema, Keyword.take(import_opts, [:module_prefix]))

    quote do
      for resource <- unquote(resources), do: @external_resource(resource)

      @doc "The imported IR schema."
      @spec __schema__() :: AshGrpc.Proto.IR.Schema.t()
      def __schema__, do: unquote(Macro.escape(schema))

      @doc "Modules compiled from the imported files."
      @spec __modules__() :: [module()]
      def __modules__, do: unquote(modules)
    end
  end

  defp eval_opts(opts, caller) do
    {opts, _} = Code.eval_quoted(opts, [], caller)
    opts
  end

  @doc false
  @spec resolve!(Keyword.t()) :: {[Path.t()], [Path.t()], Keyword.t()}
  def resolve!(opts) do
    patterns = Keyword.get(opts, :files) || raise ArgumentError, "AshGrpc.Protos requires :files"

    files =
      patterns
      |> List.wrap()
      |> Enum.flat_map(fn pattern ->
        case Path.wildcard(pattern) do
          [] -> raise ArgumentError, "AshGrpc.Protos: no files match #{inspect(pattern)}"
          files -> files
        end
      end)
      |> Enum.uniq()

    include_paths =
      case Keyword.get(opts, :include) do
        nil -> files |> Enum.map(&Path.dirname/1) |> Enum.uniq()
        paths -> List.wrap(paths)
      end

    {files, include_paths,
     Keyword.take(opts, [:module_prefix, :package_prefix, :exclude, :protoc])}
  end

  @doc false
  @spec external_resources([Path.t()], AshGrpc.Proto.IR.Schema.t(), [Path.t()]) :: [Path.t()]
  def external_resources(files, schema, include_paths) do
    imported =
      for file <- schema.files,
          include <- include_paths,
          path = Path.join(include, file.path),
          File.regular?(path),
          do: path

    (files ++ imported)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end
