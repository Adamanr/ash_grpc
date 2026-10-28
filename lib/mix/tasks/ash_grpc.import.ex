defmodule Mix.Tasks.AshGrpc.Import do
  @shortdoc "Imports foreign .proto files and generates Elixir protobuf/gRPC modules"

  @moduledoc """
  Imports foreign `.proto` files and writes Elixir modules for them
  (same shape as `protoc-gen-elixir` output, compiled from the AshGrpc IR).

      mix ash_grpc.import priv/protos/billing/**/*.proto -I priv/protos --module-prefix MyApp.Proto

  Arguments are files or glob patterns. Requires `protoc` in `PATH`.

  ## Options

    * `-I`, `--include` – import path (repeatable). Defaults to the directory
      of each input file when omitted.
    * `--out` – output directory (default: `lib/<app>/proto`)
    * `--module-prefix` – module prefix replacing the proto package
      (`protoc-gen-elixir`'s `module_prefix`)
    * `--package-prefix` – prefix prepended to the proto package in module names
    * `--protoc` – path to the `protoc` executable
    * `--check` – do not write anything; exit with an error if the generated
      files are missing or differ from the files on disk (for CI)
  """

  use Mix.Task

  @switches [
    include: :keep,
    out: :string,
    module_prefix: :string,
    package_prefix: :string,
    protoc: :string,
    check: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, patterns} = OptionParser.parse!(argv, strict: @switches, aliases: [I: :include])

    if patterns == [] do
      Mix.raise("Usage: mix ash_grpc.import FILES_OR_GLOBS [-I PATH] [--out DIR] [--check]")
    end

    files = expand(patterns)
    include_paths = include_paths(opts, files)
    out = Keyword.get_lazy(opts, :out, &default_out/0)

    import_opts =
      [include_paths: include_paths]
      |> put_opt(:protoc, opts[:protoc])
      |> put_opt(:module_prefix, opts[:module_prefix])
      |> put_opt(:package_prefix, opts[:package_prefix])

    schema =
      case AshGrpc.Proto.Import.from_files(files, import_opts) do
        {:ok, schema} -> schema
        {:error, reason} -> Mix.raise("ash_grpc.import failed: " <> format_error(reason))
      end

    # resolved at runtime so a stubbed compiler does not make the rest unreachable
    compiler = Application.get_env(:ash_grpc, :proto_compiler, AshGrpc.Proto.Compiler)

    sources =
      schema
      |> compiler.to_source(Keyword.take(import_opts, [:module_prefix]))
      |> Enum.map(fn {path, source} -> {Path.join(out, path), source} end)

    if opts[:check], do: check!(sources), else: write!(sources)
  end

  @doc false
  @spec expand([String.t()]) :: [Path.t()]
  def expand(patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      case Path.wildcard(pattern) do
        [] -> Mix.raise("No .proto files match #{inspect(pattern)}")
        files -> files
      end
    end)
    |> Enum.uniq()
  end

  # protoc requires each input to live under an import path; default to the
  # directory of every input file.
  defp include_paths(opts, files) do
    case Keyword.get_values(opts, :include) do
      [] -> files |> Enum.map(&Path.dirname/1) |> Enum.uniq()
      paths -> paths
    end
  end

  defp default_out do
    app = Mix.Project.config()[:app] || Mix.raise("--out is required outside of a Mix project")
    Path.join(["lib", Atom.to_string(app), "proto"])
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp write!(sources) do
    Enum.each(sources, fn {path, source} ->
      if File.read(path) == {:ok, source} do
        Mix.shell().info("unchanged #{path}")
      else
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, source)
        Mix.shell().info([:green, "* writing ", :reset, path])
      end
    end)
  end

  defp check!(sources) do
    stale = for {path, source} <- sources, File.read(path) != {:ok, source}, do: path

    if stale != [] do
      Mix.raise("""
      Imported protobuf modules are out of date. Run `mix ash_grpc.import` again.
      Stale files:
      #{Enum.map_join(stale, "\n", &("  * " <> &1))}
      """)
    end

    Mix.shell().info("Imported protobuf modules are up to date.")
  end

  @doc false
  @spec format_error(term()) :: String.t()
  def format_error(:protoc_not_found),
    do: "protoc executable not found in PATH (install protoc or pass --protoc PATH)"

  def format_error({:protoc_not_found, path}), do: "protoc executable not found at #{path}"

  def format_error({:protoc_failed, status, output}),
    do: "protoc exited with #{status}:\n#{output}"

  def format_error({:unsupported, message}), do: message

  def format_error({:unresolved_types, names}),
    do: "unresolved types (no definition or compiled module): #{Enum.join(names, ", ")}"

  def format_error({:module_conflict, conflicts}) do
    "several proto entities map to the same module: " <>
      Enum.map_join(conflicts, "; ", fn {module, names} ->
        "#{inspect(module)} <- #{Enum.join(names, ", ")}"
      end)
  end

  def format_error(other), do: inspect(other)
end
