defmodule AshGrpc.Proto.Import do
  @moduledoc """
  Imports foreign `.proto` files into an `AshGrpc.Proto.IR.Schema`.

  `from_files/2` runs `protoc` to produce a `FileDescriptorSet`;
  `from_descriptor_set/2` maps a descriptor set (from `protoc`, `buf build -o`,
  or server reflection) to the IR. The result can be compiled with
  `AshGrpc.Proto.Compiler` (see `mix ash_grpc.import` and `AshGrpc.Protos`).

  ## What is mapped

    * `proto2`, `proto3` and editions (`{:edition, "2023"}`) files, packages,
      imports (public imports in `public_imports`)
    * messages and enums (nested ones too), with `module` filled using
      `protoc-gen-elixir` naming (see `AshGrpc.Proto.Import.Naming`)
    * map fields → `{:map, key, value}` (the synthetic `*Entry` messages are dropped)
    * real oneofs → `IR.Oneof` + `Field.oneof`; synthetic proto3 `optional`
      oneofs are dropped and the field gets `label: :optional`. Oneof members
      have `label: nil`.
    * labels: proto2 `optional`/`required`, proto3 implicit presence (`nil`) vs
      `optional`, editions presence from `features.field_presence` (message
      fields have `nil`, `LEGACY_REQUIRED` → `:required`)
    * proto2/editions defaults, parsed to Elixir values (enum defaults are
      atoms, `inf`/`-inf`/`nan` → `:infinity`/`:negative_infinity`/`:nan`)
    * `json_name` only when it differs from the default one
    * reserved numbers (inclusive, `:max` for the maximum) and names
    * options, see `AshGrpc.Proto.Import.Options`; `deprecated`,
      `allow_alias` and `idempotency_level` become IR flags where the IR has one
    * docs from leading/trailing comments
    * `source: {:external, path}` on files, messages, enums, fields, services and rpcs

  Unsupported constructs return `{:error, {:unsupported, message}}`: proto2
  groups and `DELIMITED` message encoding (neither is supported by the
  `protobuf` library). Extension declarations (`extend Foo { ... }`) are used to
  decode custom options but are not part of the IR.

  ## Well-known and Google API types

  Files whose path starts with one of `default_excludes/0`
  (`google/protobuf/`, `google/type/`, `google/rpc/`, `google/api/`,
  `google/longrunning/`) are left out of the result: their modules already
  exist in the `protobuf` and `googleapis` libraries. References to their
  types stay plain full names; `module_for/2` resolves them to those modules.
  """

  alias AshGrpc.Proto.Import.{Mapper, Naming, Protoc, Registry}
  alias AshGrpc.Proto.IR

  @default_excludes [
    "google/protobuf/",
    "google/type/",
    "google/rpc/",
    "google/api/",
    "google/longrunning/"
  ]

  @doc "Path prefixes of files that are not imported by default."
  @spec default_excludes() :: [String.t()]
  def default_excludes, do: @default_excludes

  @doc """
  Imports `.proto` files by running `protoc`.

  Options:

    * `:include_paths` – `-I` directories used to resolve imports. Files must be
      given relative to (or inside) one of them, as with `protoc`.
    * `:protoc` – path to the `protoc` executable (default: found in `PATH`)
    * every option of `from_descriptor_set/2`

  Errors: `{:error, :protoc_not_found}`, `{:error, {:protoc_failed, status, output}}`
  and those of `from_descriptor_set/2`.
  """
  @spec from_files([Path.t()], Keyword.t()) :: {:ok, IR.Schema.t()} | {:error, term()}
  def from_files(files, opts \\ []) do
    with {:ok, binary} <- Protoc.descriptor_set(List.wrap(files), opts) do
      from_descriptor_set(binary, opts)
    end
  end

  @doc """
  Maps a `FileDescriptorSet` (encoded binary or decoded struct) to the IR.

  Options:

    * `:module_prefix` – replaces the package in module names
      (`protoc-gen-elixir`'s `module_prefix`), e.g. `MyApp.Proto`
    * `:package_prefix` – prepended to the package in module names
    * `:exclude` – path prefixes of files left out of the result
      (default: `default_excludes/0`)
    * `:validate_types?` – fail when a referenced type is neither imported nor
      available as a compiled module (default: `true`)

  Every non-excluded file of the set is returned (dependencies included, as
  their types are referenced), in the order of the descriptor set
  (dependencies first).
  """
  @spec from_descriptor_set(binary() | Google.Protobuf.FileDescriptorSet.t(), Keyword.t()) ::
          {:ok, IR.Schema.t()} | {:error, term()}
  def from_descriptor_set(set, opts \\ [])

  def from_descriptor_set(binary, opts) when is_binary(binary) do
    binary
    |> Google.Protobuf.FileDescriptorSet.decode()
    |> from_descriptor_set(opts)
  rescue
    error in Protobuf.DecodeError -> {:error, {:invalid_descriptor_set, Exception.message(error)}}
  end

  def from_descriptor_set(%Google.Protobuf.FileDescriptorSet{file: files}, opts) do
    registry = Registry.build(files)
    excludes = Keyword.get(opts, :exclude, @default_excludes)

    schema = %IR.Schema{
      files:
        files
        |> Enum.reject(&excluded?(&1.name, excludes))
        |> Enum.map(&Mapper.file(&1, registry, opts))
    }

    with :ok <- check_modules(schema),
         :ok <- check_types(schema, registry, opts) do
      {:ok, schema}
    end
  rescue
    error in [Mapper.Error, ArgumentError] -> {:error, {:unsupported, Exception.message(error)}}
  end

  @doc """
  Elixir module of a message/enum referenced by full name: the imported one if
  it is part of `schema`, otherwise the well-known/`googleapis` module.
  """
  @spec module_for(IR.Schema.t() | nil, IR.full_name()) :: module()
  def module_for(schema, full_name) do
    with %IR.Schema{} <- schema,
         {:ok, %{module: module}} when not is_nil(module) <- IR.Schema.lookup(schema, full_name) do
      module
    else
      _ -> Naming.external_module(full_name)
    end
  end

  @doc "Returns true if `path` starts with one of the `excludes` prefixes."
  @spec excluded?(String.t(), [String.t()]) :: boolean()
  def excluded?(path, excludes \\ @default_excludes),
    do: Enum.any?(excludes, &String.starts_with?(path, &1))

  defp check_modules(schema) do
    schema
    |> entities()
    |> Enum.group_by(& &1.module, & &1.full_name)
    |> Enum.filter(fn {_module, names} -> length(names) > 1 end)
    |> case do
      [] -> :ok
      conflicts -> {:error, {:module_conflict, Map.new(conflicts)}}
    end
  end

  defp check_types(schema, registry, opts) do
    if Keyword.get(opts, :validate_types?, true) do
      local = schema |> entities() |> MapSet.new(& &1.full_name)

      schema
      |> referenced_types()
      |> Enum.reject(&(MapSet.member?(local, &1) or external?(&1, registry)))
      |> case do
        [] -> :ok
        missing -> {:error, {:unresolved_types, Enum.sort(missing)}}
      end
    else
      :ok
    end
  end

  # defined in an excluded file (or well-known) and available as a compiled module
  defp external?(name, registry) do
    (Map.has_key?(registry.files, name) or AshGrpc.Proto.WellKnown.well_known?(name)) and
      Code.ensure_loaded?(Naming.external_module(name))
  end

  defp entities(schema) do
    Enum.flat_map(schema.files, fn file ->
      file.services ++ types(file.messages, file.enums)
    end)
  end

  defp types(messages, enums) do
    enums ++
      Enum.flat_map(messages, fn message ->
        [message | types(message.nested_messages, message.nested_enums)]
      end)
  end

  defp referenced_types(schema) do
    schema.files
    |> Enum.flat_map(fn file ->
      field_refs =
        file.messages
        |> types([])
        |> Enum.flat_map(fn
          %IR.Message{fields: fields} -> Enum.flat_map(fields, &type_refs(&1.type))
          _enum -> []
        end)

      rpc_refs =
        Enum.flat_map(file.services, fn service ->
          Enum.flat_map(service.rpcs, &[&1.input, &1.output])
        end)

      field_refs ++ rpc_refs
    end)
    |> Enum.uniq()
  end

  defp type_refs({:message, name}), do: [name]
  defp type_refs({:enum, name}), do: [name]
  defp type_refs({:map, _key, value}), do: type_refs(value)
  defp type_refs(_scalar), do: []
end
