defmodule AshGrpc.Type.Mapping do
  @moduledoc """
  Maps Ash types to protobuf field types.

  > #### Foundation implementation {: .warning}
  >
  > This module currently implements only scalars, arrays and well-known types.
  > Enums (`Ash.Type.Enum`, `:atom` with `one_of`), embedded resources, typed
  > maps/structs (`fields` constraint), unions (→ `oneof`), keywords/tuples and
  > alternative representations are owned by the "types & codec" work package
  > (see DESIGN.md). The public contract (`to_proto/3` and `Result`) is stable.

  ## Options

    * `:allow_nil?` – whether the value may be `nil` (default `true`). Nullable
      scalars get `label: :optional` (explicit presence).
    * `:package` – proto package used for generated messages/enums.
    * `:name_hint` – base name for generated messages/enums (e.g. `"UserRole"`).
    * `:representation` – per-field override of the default representation,
      e.g. `:string`, `:int32`, `{:message, "google.type.Decimal"}`.
  """

  alias AshGrpc.Proto.{IR, WellKnown}
  require IR

  defmodule Result do
    @moduledoc """
    Result of mapping an Ash type.

      * `type`/`label` – go straight into `AshGrpc.Proto.IR.Field`
      * `messages`/`enums` – extra top-level definitions the type needs
        (deduplicated by `full_name` by the caller)
      * `imports` – import paths the file needs
    """
    defstruct [:type, label: nil, messages: [], enums: [], imports: []]

    @type t :: %__MODULE__{
            type: IR.field_type(),
            label: IR.label(),
            messages: [IR.Message.t()],
            enums: [IR.Enum.t()],
            imports: [String.t()]
          }
  end

  @scalars %{
    Ash.Type.String => :string,
    Ash.Type.CiString => :string,
    Ash.Type.Integer => :int64,
    Ash.Type.Float => :double,
    Ash.Type.Boolean => :bool,
    Ash.Type.Decimal => :string,
    Ash.Type.UUID => :string,
    Ash.Type.UUIDv7 => :string,
    Ash.Type.Binary => :bytes,
    Ash.Type.Atom => :string,
    Ash.Type.Date => :string,
    Ash.Type.Time => :string,
    Ash.Type.NaiveDatetime => :string
  }

  @messages %{
    Ash.Type.UtcDatetime => "google.protobuf.Timestamp",
    Ash.Type.UtcDatetimeUsec => "google.protobuf.Timestamp",
    Ash.Type.DateTime => "google.protobuf.Timestamp",
    Ash.Type.Duration => "google.protobuf.Duration",
    Ash.Type.Map => "google.protobuf.Struct"
  }

  @doc "Maps an Ash type (short name or module, may be `{:array, type}`) to a proto field type."
  @spec to_proto(Ash.Type.t(), Keyword.t(), Keyword.t()) :: {:ok, Result.t()} | {:error, term()}
  def to_proto(type, constraints \\ [], opts \\ [])

  def to_proto({:array, inner}, constraints, opts) do
    with {:ok, %Result{} = result} <-
           to_proto(
             inner,
             Keyword.get(constraints, :items, []),
             Keyword.put(opts, :allow_nil?, false)
           ) do
      case result.type do
        {:map, _, _} -> {:error, {:unsupported, {:array, inner}, "repeated maps are not allowed"}}
        _ -> {:ok, %{result | label: :repeated}}
      end
    end
  end

  def to_proto(type, constraints, opts) do
    type = Ash.Type.get_type(type)

    cond do
      representation = opts[:representation] ->
        {:ok, finalize(%Result{type: representation}, opts)}

      Code.ensure_loaded?(type) and function_exported?(type, :proto_type, 1) ->
        with {:ok, result} <- type.proto_type(constraints), do: {:ok, finalize(result, opts)}

      Ash.Type.NewType.new_type?(type) ->
        to_proto(
          Ash.Type.NewType.subtype_of(type),
          Ash.Type.NewType.constraints(type, constraints),
          opts
        )

      scalar = Map.get(@scalars, type) ->
        {:ok, finalize(%Result{type: scalar}, opts)}

      full_name = Map.get(@messages, type) ->
        {:ok, finalize(%Result{type: {:message, full_name}}, opts)}

      true ->
        {:error, {:unsupported, type, "no protobuf mapping for this Ash type"}}
    end
  end

  defp finalize(%Result{} = result, opts) do
    result
    |> put_label(Keyword.get(opts, :allow_nil?, true))
    |> put_imports()
  end

  # Scalars need explicit presence to distinguish nil from the default value.
  # Messages always have presence; repeated fields cannot be optional.
  defp put_label(%Result{label: nil, type: type} = result, true) when IR.is_scalar(type),
    do: %{result | label: :optional}

  defp put_label(%Result{label: nil, type: {:enum, _}} = result, true),
    do: %{result | label: :optional}

  defp put_label(result, _), do: result

  defp put_imports(%Result{type: {:message, full_name}} = result) do
    case WellKnown.import_path(full_name) do
      nil -> result
      path -> %{result | imports: Enum.uniq([path | result.imports])}
    end
  end

  defp put_imports(result), do: result
end
