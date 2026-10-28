defmodule AshGrpc.Codegen.Snapshot do
  @moduledoc """
  JSON snapshots of generated `.proto` files: the baseline `mix ash_grpc.codegen` diffs against.

  Every generated `AshGrpc.Proto.IR.File` gets one snapshot next to the lock, at
  `priv/grpc/snapshots/<proto path without .proto>.json`. The snapshot is the IR of the file
  as it was last generated, so the next run can compute `AshGrpc.Proto.Diff.diff(old, new)`
  without `protoc` (re-importing the old `.proto` would require it) and without parsing
  proto text.

  ## Format (version 1)

      {
        "version": 1,
        "generator": "ash_grpc",
        "domain": "MyApp.Accounts",
        "file": {
          "path": "myapp/accounts/v1/accounts.proto",
          "package": "myapp.accounts.v1",
          "syntax": "proto3",
          "imports": ["google/protobuf/timestamp.proto"],
          "messages": [
            {"name": "User", "full_name": "myapp.accounts.v1.User",
             "fields": [{"name": "id", "number": 1, "type": "string"}, ...],
             "reserved_numbers": [3, [10, 12]], "reserved_names": ["legacy"]}
          ],
          "enums": [...],
          "services": [...]
        }
      }

  Keys mirror the IR struct fields; `nil`, `false` and `[]` values are omitted. Field types
  are a scalar name, `{"message": full_name}`, `{"enum": full_name}` or
  `{"map": [key_scalar, value_type]}`. Option values and proto2 defaults are JSON scalars,
  `{"atom": name}` for atoms (enum constants, `inf`/`nan`), arrays for lists and
  `{"map": [[key, value], ...]}` for message literals.

  Snapshots keep everything that ends up in the `.proto` file (including docs and options),
  but not `source` and `module` (Elixir-side data that does not affect the wire format).
  Encoding is deterministic: the same IR always gives the same bytes.

  Snapshots are trusted project files (they live in the repository next to the code), so
  atoms in option values are created on decode; protobuf scalars, labels and syntaxes are
  decoded from fixed lists.
  """

  alias AshGrpc.Proto.IR

  @version 1
  @generator "ash_grpc"

  @scalars Map.new(IR.scalars(), &{Atom.to_string(&1), &1})
  @labels %{"optional" => :optional, "repeated" => :repeated, "required" => :required}
  @idempotency %{"no_side_effects" => :no_side_effects, "idempotent" => :idempotent}

  @typedoc "A decoded snapshot: the file and the name of the domain it was generated from."
  @type t :: %{file: IR.File.t(), domain: String.t() | nil}

  @doc "Path of the snapshot of the proto file `proto_path` inside `dir`."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(dir, proto_path), do: Path.join(dir, Path.rootname(proto_path) <> ".json")

  @doc """
  Encodes a file as snapshot JSON (pretty-printed, trailing newline). `domain` is the domain
  module (or its name) recorded as the origin of the file.
  """
  @spec encode(IR.File.t(), module() | String.t() | nil) :: String.t()
  def encode(%IR.File{} = file, domain \\ nil) do
    object(
      version: @version,
      generator: @generator,
      domain: domain_name(domain),
      file: encode_file(file)
    )
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc "Decodes snapshot JSON."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) do
    with {:ok, data} <- Jason.decode(json),
         :ok <- check_header(data) do
      {:ok, %{file: decode_file(data["file"]), domain: data["domain"]}}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError, CaseClauseError, BadMapError] ->
      {:error, {:invalid_snapshot, Exception.message(error)}}
  end

  @doc "Whether the JSON contents look like an AshGrpc snapshot (used before deleting files)."
  @spec snapshot?(String.t()) :: boolean()
  def snapshot?(json) do
    match?({:ok, %{"generator" => @generator}}, Jason.decode(json))
  end

  @doc """
  Loads every snapshot under `dir` (recursively), sorted by path. A missing directory yields
  no snapshots. Returns `{path, snapshot}` pairs.
  """
  @spec load_dir(Path.t()) :: {:ok, [{Path.t(), t()}]} | {:error, term()}
  def load_dir(dir) do
    dir
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case load_file(path) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, snapshot} -> {:cont, {:ok, [{path, snapshot} | acc]}}
        {:error, reason} -> {:halt, {:error, {:snapshot, path, reason}}}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  # nil for JSON files that are not snapshots
  defp load_file(path) do
    contents = Elixir.File.read!(path)
    if snapshot?(contents), do: decode(contents), else: {:ok, nil}
  end

  defp check_header(%{"version" => @version, "generator" => @generator}), do: :ok

  defp check_header(%{"version" => version, "generator" => @generator}),
    do: {:error, {:unsupported_version, version}}

  defp check_header(_), do: {:error, :not_a_snapshot}

  defp domain_name(nil), do: nil
  defp domain_name(domain) when is_binary(domain), do: domain
  defp domain_name(domain) when is_atom(domain), do: inspect(domain)

  # -- encoding -----------------------------------------------------------------------------

  defp encode_file(%IR.File{} = file) do
    object(
      path: file.path,
      package: file.package,
      syntax: encode_syntax(file.syntax),
      doc: file.doc,
      imports: file.imports,
      public_imports: file.public_imports,
      options: encode_options(file.options),
      messages: Enum.map(file.messages, &encode_message/1),
      enums: Enum.map(file.enums, &encode_enum/1),
      services: Enum.map(file.services, &encode_service/1)
    )
  end

  defp encode_syntax(:proto3), do: "proto3"
  defp encode_syntax(:proto2), do: "proto2"
  defp encode_syntax({:edition, edition}), do: object(edition: edition)

  defp encode_message(%IR.Message{} = message) do
    object(
      name: message.name,
      full_name: message.full_name,
      doc: message.doc,
      fields: Enum.map(message.fields, &encode_field/1),
      oneofs: Enum.map(message.oneofs, &encode_oneof/1),
      nested_messages: Enum.map(message.nested_messages, &encode_message/1),
      nested_enums: Enum.map(message.nested_enums, &encode_enum/1),
      reserved_numbers: encode_reserved(message.reserved_numbers),
      reserved_names: message.reserved_names,
      options: encode_options(message.options)
    )
  end

  defp encode_field(%IR.Field{} = field) do
    object(
      name: field.name,
      number: field.number,
      type: encode_type(field.type),
      label: field.label && Atom.to_string(field.label),
      oneof: field.oneof,
      json_name: field.json_name,
      default: if(is_nil(field.default), do: nil, else: encode_value(field.default)),
      doc: field.doc,
      deprecated: field.deprecated?,
      options: encode_options(field.options)
    )
  end

  defp encode_type(scalar) when is_atom(scalar), do: Atom.to_string(scalar)
  defp encode_type({:message, name}), do: object(message: name)
  defp encode_type({:enum, name}), do: object(enum: name)
  defp encode_type({:map, key, value}), do: object(map: [encode_type(key), encode_type(value)])

  defp encode_oneof(%IR.Oneof{} = oneof) do
    object(name: oneof.name, doc: oneof.doc, options: encode_options(oneof.options))
  end

  defp encode_enum(%IR.Enum{} = enum) do
    object(
      name: enum.name,
      full_name: enum.full_name,
      doc: enum.doc,
      allow_alias: enum.allow_alias?,
      values: Enum.map(enum.values, &encode_enum_value/1),
      reserved_numbers: encode_reserved(enum.reserved_numbers),
      reserved_names: enum.reserved_names,
      options: encode_options(enum.options)
    )
  end

  defp encode_enum_value(%IR.EnumValue{} = value) do
    object(
      name: value.name,
      number: value.number,
      doc: value.doc,
      deprecated: value.deprecated?,
      options: encode_options(value.options)
    )
  end

  defp encode_service(%IR.Service{} = service) do
    object(
      name: service.name,
      full_name: service.full_name,
      doc: service.doc,
      rpcs: Enum.map(service.rpcs, &encode_rpc/1),
      options: encode_options(service.options)
    )
  end

  defp encode_rpc(%IR.Rpc{} = rpc) do
    object(
      name: rpc.name,
      input: rpc.input,
      output: rpc.output,
      doc: rpc.doc,
      client_streaming: rpc.client_streaming?,
      server_streaming: rpc.server_streaming?,
      idempotency_level: rpc.idempotency_level && Atom.to_string(rpc.idempotency_level),
      deprecated: rpc.deprecated?,
      options: encode_options(rpc.options)
    )
  end

  defp encode_reserved(numbers) do
    Enum.map(numbers, fn
      {from, :max} -> [from, "max"]
      {from, to} -> [from, to]
      number -> number
    end)
  end

  defp encode_options(options) do
    Enum.map(options, fn %IR.Option{name: name, value: value} ->
      Jason.OrderedObject.new(name: to_string(name), value: encode_value(value))
    end)
  end

  defp encode_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp encode_value(value) when is_atom(value), do: object(atom: Atom.to_string(value))
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    pairs =
      value
      |> Enum.map(fn {key, val} -> [encode_value(key), encode_value(val)] end)
      |> Enum.sort_by(fn [key, _] -> Jason.encode!(key) end)

    Jason.OrderedObject.new(map: pairs)
  end

  # Drops empty values so snapshots stay small; decoding falls back to the struct defaults.
  defp object(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> value in [nil, false, []] end)
    |> Jason.OrderedObject.new()
  end

  # -- decoding -----------------------------------------------------------------------------

  defp decode_file(data) do
    %IR.File{
      path: Map.fetch!(data, "path"),
      package: data["package"],
      syntax: decode_syntax(data["syntax"] || "proto3"),
      doc: data["doc"],
      imports: list(data, "imports"),
      public_imports: list(data, "public_imports"),
      options: decode_options(data),
      messages: Enum.map(list(data, "messages"), &decode_message/1),
      enums: Enum.map(list(data, "enums"), &decode_enum/1),
      services: Enum.map(list(data, "services"), &decode_service/1)
    }
  end

  defp decode_syntax("proto3"), do: :proto3
  defp decode_syntax("proto2"), do: :proto2
  defp decode_syntax(%{"edition" => edition}) when is_binary(edition), do: {:edition, edition}

  defp decode_message(data) do
    %IR.Message{
      name: Map.fetch!(data, "name"),
      full_name: Map.fetch!(data, "full_name"),
      doc: data["doc"],
      fields: Enum.map(list(data, "fields"), &decode_field/1),
      oneofs: Enum.map(list(data, "oneofs"), &decode_oneof/1),
      nested_messages: Enum.map(list(data, "nested_messages"), &decode_message/1),
      nested_enums: Enum.map(list(data, "nested_enums"), &decode_enum/1),
      reserved_numbers: decode_reserved(list(data, "reserved_numbers")),
      reserved_names: list(data, "reserved_names"),
      options: decode_options(data)
    }
  end

  defp decode_field(data) do
    %IR.Field{
      name: Map.fetch!(data, "name"),
      number: data["number"],
      type: decode_type(Map.fetch!(data, "type")),
      label: decode_label(data["label"]),
      oneof: data["oneof"],
      json_name: data["json_name"],
      default: if(Map.has_key?(data, "default"), do: decode_value(data["default"])),
      doc: data["doc"],
      deprecated?: data["deprecated"] == true,
      options: decode_options(data)
    }
  end

  defp decode_type(%{"message" => name}) when is_binary(name), do: {:message, name}
  defp decode_type(%{"enum" => name}) when is_binary(name), do: {:enum, name}

  defp decode_type(%{"map" => [key, value]}),
    do: {:map, decode_type(key), decode_type(value)}

  defp decode_type(scalar) when is_binary(scalar), do: Map.fetch!(@scalars, scalar)

  defp decode_label(nil), do: nil
  defp decode_label(label), do: Map.fetch!(@labels, label)

  defp decode_oneof(data) do
    %IR.Oneof{name: Map.fetch!(data, "name"), doc: data["doc"], options: decode_options(data)}
  end

  defp decode_enum(data) do
    %IR.Enum{
      name: Map.fetch!(data, "name"),
      full_name: Map.fetch!(data, "full_name"),
      doc: data["doc"],
      allow_alias?: data["allow_alias"] == true,
      values: Enum.map(list(data, "values"), &decode_enum_value/1),
      reserved_numbers: decode_reserved(list(data, "reserved_numbers")),
      reserved_names: list(data, "reserved_names"),
      options: decode_options(data)
    }
  end

  defp decode_enum_value(data) do
    %IR.EnumValue{
      name: Map.fetch!(data, "name"),
      number: Map.fetch!(data, "number"),
      doc: data["doc"],
      deprecated?: data["deprecated"] == true,
      options: decode_options(data)
    }
  end

  defp decode_service(data) do
    %IR.Service{
      name: Map.fetch!(data, "name"),
      full_name: Map.fetch!(data, "full_name"),
      doc: data["doc"],
      rpcs: Enum.map(list(data, "rpcs"), &decode_rpc/1),
      options: decode_options(data)
    }
  end

  defp decode_rpc(data) do
    %IR.Rpc{
      name: Map.fetch!(data, "name"),
      input: Map.fetch!(data, "input"),
      output: Map.fetch!(data, "output"),
      doc: data["doc"],
      client_streaming?: data["client_streaming"] == true,
      server_streaming?: data["server_streaming"] == true,
      idempotency_level:
        data["idempotency_level"] && Map.fetch!(@idempotency, data["idempotency_level"]),
      deprecated?: data["deprecated"] == true,
      options: decode_options(data)
    }
  end

  defp decode_reserved(numbers) do
    Enum.map(numbers, fn
      [from, "max"] when is_integer(from) -> {from, :max}
      [from, to] when is_integer(from) and is_integer(to) -> {from, to}
      number when is_integer(number) -> number
    end)
  end

  defp decode_options(data) do
    data
    |> list("options")
    |> Enum.map(fn %{"name" => name, "value" => value} ->
      %IR.Option{name: name, value: decode_value(value)}
    end)
  end

  # Snapshots are trusted project files, never wire data (see the module docs).
  defp decode_value(%{"atom" => name}) when is_binary(name), do: String.to_atom(name)

  defp decode_value(%{"map" => pairs}) when is_list(pairs),
    do: Map.new(pairs, fn [key, value] -> {decode_value(key), decode_value(value)} end)

  defp decode_value(values) when is_list(values), do: Enum.map(values, &decode_value/1)

  defp decode_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp list(data, key) do
    case Map.get(data, key, []) do
      list when is_list(list) -> list
    end
  end
end
