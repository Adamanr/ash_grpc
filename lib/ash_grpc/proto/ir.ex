defmodule AshGrpc.Proto.IR do
  @moduledoc """
  Intermediate representation (IR) of protobuf schemas.

  The IR is the central contract of AshGrpc. Every pipeline goes through it:

      Ash DSL (grpc do ... end) ──► IR ──► .proto text          (AshGrpc.Proto.Render)
                                    ├──► Elixir protobuf modules (AshGrpc.Proto.Compiler)
                                    └──► field-number lock       (AshGrpc.Proto.Lock)
      foreign .proto files ──────► IR ──► client stubs / remote resources (AshGrpc.Proto.Import)
      IR (old) + IR (new) ───────► breaking-change report        (AshGrpc.Proto.Diff)

  Conventions:

    * Type references are **fully-qualified proto names without a leading dot**,
      e.g. `"google.protobuf.Timestamp"` or `"myapp.accounts.v1.User"`.
    * Nested types are referenced by their full name too (`"pkg.Outer.Inner"`).
    * Names are kept exactly as they appear in the `.proto` (no case conversion
      happens inside the IR). Builders decide names, renderers print them.
    * `:source` fields carry provenance back to Ash (resource, attribute, action)
      and are ignored by the renderer. They are used for runtime dispatch and
      error messages.
    * `:module` fields hold the Elixir module that represents the proto entity at
      runtime (protobuf message struct, enum module, `GRPC.Service` module). They
      are filled by the builder/importer and consumed by the compiler and runtime.
  """

  @typedoc "Fully-qualified proto name, without leading dot."
  @type full_name :: String.t()

  @type scalar ::
          :double
          | :float
          | :int32
          | :int64
          | :uint32
          | :uint64
          | :sint32
          | :sint64
          | :fixed32
          | :fixed64
          | :sfixed32
          | :sfixed64
          | :bool
          | :string
          | :bytes

  @typedoc """
  Field type.

    * a scalar atom
    * `{:message, full_name}` / `{:enum, full_name}`
    * `{:map, key_scalar, value_type}` – `value_type` is a scalar, message or enum (never a map)
  """
  @type field_type ::
          scalar()
          | {:message, full_name()}
          | {:enum, full_name()}
          | {:map, scalar(), scalar() | {:message, full_name()} | {:enum, full_name()}}

  @typedoc """
  Field label.

    * `nil` – proto3 implicit presence (singular, default value == absent)
    * `:optional` – explicit presence (proto3 `optional`, or proto2 optional)
    * `:repeated`
    * `:required` – proto2 only
  """
  @type label :: nil | :optional | :repeated | :required

  @typedoc "Reserved numbers: single numbers or inclusive ranges (`max` allowed as upper bound)."
  @type reserved_number :: non_neg_integer() | {non_neg_integer(), non_neg_integer() | :max}

  @scalars ~w(double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes)a

  @doc "All protobuf scalar types."
  @spec scalars() :: [scalar()]
  def scalars, do: @scalars

  @doc "Returns true for protobuf scalar type atoms."
  defguard is_scalar(type) when type in @scalars

  @doc "Joins a package and a (possibly nested) name into a full name."
  @spec full_name(String.t() | nil, String.t()) :: full_name()
  def full_name(nil, name), do: name
  def full_name("", name), do: name
  def full_name(package, name), do: package <> "." <> name

  defmodule Option do
    @moduledoc """
    A proto option (`option java_package = "...";`, `[deprecated = true]`, custom `(my.ext).opt`).

    `value` is printed as a proto constant: strings are quoted, atoms are printed
    as identifiers (enum constants such as `SPEED`), booleans/numbers as-is, and
    maps as message literals (`{ a: 1 }`) for aggregate custom options.
    """
    defstruct [:name, :value]

    @type t :: %__MODULE__{
            name: String.t(),
            value: String.t() | atom() | boolean() | number() | map()
          }
  end

  defmodule Field do
    @moduledoc "A message field."
    defstruct [
      :name,
      :number,
      :type,
      :label,
      :oneof,
      :json_name,
      :default,
      :doc,
      :source,
      deprecated?: false,
      options: []
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            number: pos_integer() | nil,
            type: AshGrpc.Proto.IR.field_type(),
            label: AshGrpc.Proto.IR.label(),
            oneof: String.t() | nil,
            json_name: String.t() | nil,
            default: term(),
            doc: String.t() | nil,
            source: term(),
            deprecated?: boolean(),
            options: [AshGrpc.Proto.IR.Option.t()]
          }
  end

  defmodule Oneof do
    @moduledoc "A oneof group. Fields reference it via `Field.oneof`."
    defstruct [:name, :doc, options: []]

    @type t :: %__MODULE__{
            name: String.t(),
            doc: String.t() | nil,
            options: [AshGrpc.Proto.IR.Option.t()]
          }
  end

  defmodule EnumValue do
    @moduledoc "An enum value. `source` is the Ash atom it represents (if any)."
    defstruct [:name, :number, :doc, :source, deprecated?: false, options: []]

    @type t :: %__MODULE__{
            name: String.t(),
            number: integer(),
            doc: String.t() | nil,
            source: atom() | nil,
            deprecated?: boolean(),
            options: [AshGrpc.Proto.IR.Option.t()]
          }
  end

  defmodule Enum do
    @moduledoc """
    An enum. In proto3 the first value must be `0`; AshGrpc builders always emit
    `<PREFIX>_UNSPECIFIED = 0` for Ash enums.
    """
    defstruct [
      :name,
      :full_name,
      :module,
      :doc,
      :source,
      values: [],
      reserved_numbers: [],
      reserved_names: [],
      allow_alias?: false,
      options: []
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            full_name: AshGrpc.Proto.IR.full_name(),
            module: module() | nil,
            doc: String.t() | nil,
            source: term(),
            values: [AshGrpc.Proto.IR.EnumValue.t()],
            reserved_numbers: [AshGrpc.Proto.IR.reserved_number()],
            reserved_names: [String.t()],
            allow_alias?: boolean(),
            options: [AshGrpc.Proto.IR.Option.t()]
          }
  end

  defmodule Message do
    @moduledoc """
    A message.

    `source` examples (set by builders, free-form but these shapes are reserved):

      * `{:resource, resource}` – the record message of a resource
      * `{:action_input, resource, action}` / `{:action_output, resource, action}`
      * `{:embedded, resource}` – an embedded resource
      * `{:type, ash_type, constraints}` – a generated message for a complex Ash type
      * `{:external, path}` – imported from a foreign .proto
    """
    defstruct [
      :name,
      :full_name,
      :module,
      :doc,
      :source,
      fields: [],
      oneofs: [],
      nested_messages: [],
      nested_enums: [],
      reserved_numbers: [],
      reserved_names: [],
      options: []
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            full_name: AshGrpc.Proto.IR.full_name(),
            module: module() | nil,
            doc: String.t() | nil,
            source: term(),
            fields: [AshGrpc.Proto.IR.Field.t()],
            oneofs: [AshGrpc.Proto.IR.Oneof.t()],
            nested_messages: [t()],
            nested_enums: [AshGrpc.Proto.IR.Enum.t()],
            reserved_numbers: [AshGrpc.Proto.IR.reserved_number()],
            reserved_names: [String.t()],
            options: [AshGrpc.Proto.IR.Option.t()]
          }
  end

  defmodule Rpc do
    @moduledoc """
    A service method.

    `source` for Ash-backed rpcs is `{:action, resource, action_name, rpc_opts}`;
    for imported ones `{:external, path}`.
    """
    defstruct [
      :name,
      :input,
      :output,
      :doc,
      :source,
      client_streaming?: false,
      server_streaming?: false,
      idempotency_level: nil,
      deprecated?: false,
      options: []
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            input: AshGrpc.Proto.IR.full_name(),
            output: AshGrpc.Proto.IR.full_name(),
            doc: String.t() | nil,
            source: term(),
            client_streaming?: boolean(),
            server_streaming?: boolean(),
            idempotency_level: nil | :no_side_effects | :idempotent,
            deprecated?: boolean(),
            options: [AshGrpc.Proto.IR.Option.t()]
          }
  end

  defmodule Service do
    @moduledoc "A service."
    defstruct [:name, :full_name, :module, :doc, :source, rpcs: [], options: []]

    @type t :: %__MODULE__{
            name: String.t(),
            full_name: AshGrpc.Proto.IR.full_name(),
            module: module() | nil,
            doc: String.t() | nil,
            source: term(),
            rpcs: [AshGrpc.Proto.IR.Rpc.t()],
            options: [AshGrpc.Proto.IR.Option.t()]
          }
  end

  defmodule File do
    @moduledoc """
    A `.proto` file.

    `path` is the import path relative to the proto root
    (e.g. `"myapp/accounts/v1/accounts.proto"`). `imports` are import paths
    (`"google/protobuf/timestamp.proto"`), `public_imports` are re-exported.
    """
    defstruct [
      :path,
      :package,
      :doc,
      :source,
      syntax: :proto3,
      imports: [],
      public_imports: [],
      options: [],
      messages: [],
      enums: [],
      services: []
    ]

    @type t :: %__MODULE__{
            path: String.t(),
            package: String.t() | nil,
            doc: String.t() | nil,
            source: term(),
            syntax: :proto2 | :proto3 | {:edition, String.t()},
            imports: [String.t()],
            public_imports: [String.t()],
            options: [AshGrpc.Proto.IR.Option.t()],
            messages: [AshGrpc.Proto.IR.Message.t()],
            enums: [AshGrpc.Proto.IR.Enum.t()],
            services: [AshGrpc.Proto.IR.Service.t()]
          }
  end

  defmodule Schema do
    @moduledoc """
    A set of files that reference each other (the equivalent of a
    `FileDescriptorSet`). Well-known types (`google/protobuf/*.proto`) are not
    required to be present: they are resolved by `AshGrpc.Proto.WellKnown`.
    """
    defstruct files: []

    @type t :: %__MODULE__{files: [AshGrpc.Proto.IR.File.t()]}

    @doc "Finds a message or enum (including nested ones) by full name."
    @spec lookup(t(), AshGrpc.Proto.IR.full_name()) ::
            {:ok, AshGrpc.Proto.IR.Message.t() | AshGrpc.Proto.IR.Enum.t()} | :error
    def lookup(%__MODULE__{files: files}, full_name) do
      files
      |> Stream.flat_map(fn file -> types(file.messages, file.enums) end)
      |> Elixir.Enum.find(&(&1.full_name == full_name))
      |> case do
        nil -> :error
        found -> {:ok, found}
      end
    end

    @doc "Finds a service by full name."
    @spec lookup_service(t(), AshGrpc.Proto.IR.full_name()) ::
            {:ok, AshGrpc.Proto.IR.Service.t()} | :error
    def lookup_service(%__MODULE__{files: files}, full_name) do
      files
      |> Stream.flat_map(& &1.services)
      |> Elixir.Enum.find(&(&1.full_name == full_name))
      |> case do
        nil -> :error
        found -> {:ok, found}
      end
    end

    defp types(messages, enums) do
      enums ++
        Elixir.Enum.flat_map(messages, fn message ->
          [message | types(message.nested_messages, message.nested_enums)]
        end)
    end
  end
end
