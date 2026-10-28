defmodule AshGrpc.Error do
  @moduledoc """
  Converts Ash errors to gRPC statuses and back.

  ## Ash → gRPC (`to_rpc_error/2`)

  | Ash | gRPC status | details |
  |---|---|---|
  | `Ash.Error.Changes.InvalidAttribute`/`InvalidArgument`/`Required`/`InvalidChanges`, `Ash.Error.Query.InvalidArgument`/`Required`, `Ash.Error.Invalid.NoSuchInput`, … | `INVALID_ARGUMENT` | `google.rpc.BadRequest` (field path = proto field path) |
  | `Ash.Error.Query.NotFound` | `NOT_FOUND` | `google.rpc.ResourceInfo` |
  | `Ash.Error.Forbidden.*` | `PERMISSION_DENIED` | no policy breakdown |
  | actor required (`*RequiresActor`), `AshGrpc.Error.Unauthenticated` | `UNAUTHENTICATED` | |
  | `Ash.Error.Changes.StaleRecord` | `ABORTED` | |
  | unique constraint violation (`InvalidAttribute` with `constraint_type: :unique`) | `ALREADY_EXISTS` | `google.rpc.BadRequest` |
  | `Ash.Error.Invalid.Timeout` | `DEADLINE_EXCEEDED` | |
  | `Ash.Error.Unknown`, any other exception or term | `INTERNAL` | message hidden unless `show_raised_errors?` |

  Every status carries a `google.rpc.ErrorInfo` (`reason`, `domain`, safe
  `metadata`). Details are returned in `GRPC.RPCError.details` as
  `google.protobuf.Any` messages; the gRPC server adapter encodes them as the
  `google.rpc.Status` in the `grpc-status-details-bin` trailer.

  Error classes (`Ash.Error.Invalid` etc.) are flattened; when they contain
  errors with different codes the most specific one wins (e.g. `NOT_FOUND`
  over `INVALID_ARGUMENT`, any known code over `INTERNAL`). Field violations of
  all errors are reported.

  The conversion of a single error is defined by the `AshGrpc.ToStatus`
  protocol, so you can add your own exceptions.

  ## gRPC → Ash (`from_rpc_error/2`)

  | gRPC status | Ash error |
  |---|---|
  | `INVALID_ARGUMENT`, `OUT_OF_RANGE`, `FAILED_PRECONDITION`, `ALREADY_EXISTS` with `BadRequest` | `Ash.Error.Invalid` with `Ash.Error.Changes.InvalidAttribute` per field violation |
  | `NOT_FOUND` | `Ash.Error.Invalid` with `Ash.Error.Query.NotFound` |
  | `PERMISSION_DENIED`, `UNAUTHENTICATED` | `Ash.Error.Forbidden` with `AshGrpc.Error.RemoteError` |
  | other invalid-like statuses without violations | `Ash.Error.Invalid` with `AshGrpc.Error.RemoteError` |
  | everything else | `Ash.Error.Unknown` with `AshGrpc.Error.RemoteError` |

  `AshGrpc.Error.RemoteError` keeps the status code, message and the decoded
  `ErrorInfo`/`ResourceInfo`/other details.

  ## Configuration

      config :ash_grpc, show_raised_errors?: true   # default false; never in production
      config :ash_grpc, error_domain: "myapp.example.com"  # ErrorInfo.domain, default "ash"
  """

  alias AshGrpc.Error.{Details, Info, RemoteError}
  alias AshGrpc.Proto.IR
  alias AshGrpc.Type.Naming
  alias Google.Rpc.{BadRequest, ErrorInfo, ResourceInfo}

  # most specific first
  @precedence [
    :unauthenticated,
    :permission_denied,
    :not_found,
    :already_exists,
    :aborted,
    :deadline_exceeded,
    :failed_precondition,
    :out_of_range,
    :invalid_argument,
    :resource_exhausted,
    :unavailable,
    :unimplemented,
    :cancelled,
    :data_loss,
    :unknown,
    :internal
  ]

  @generic_messages %{
    internal: "internal error",
    unknown: "unknown error",
    data_loss: "internal error",
    invalid_argument: "invalid request",
    permission_denied: "forbidden",
    unauthenticated: "unauthenticated",
    not_found: "not found",
    unavailable: "service unavailable"
  }

  @invalid_codes [
    :invalid_argument,
    :out_of_range,
    :failed_precondition,
    :already_exists,
    :aborted
  ]
  @forbidden_codes [:permission_denied, :unauthenticated]

  @class_modules [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Framework, Ash.Error.Unknown]

  @doc """
  Converts an Ash error (class or single error, a list, a changeset/query with
  errors, any exception or term) into a `GRPC.RPCError`.

  Options:

    * `:show_raised_errors?` – include messages of internal errors (and a
      `google.rpc.DebugInfo`). Defaults to `config :ash_grpc, :show_raised_errors?`
      (`false`).
    * `:message` – the `IR.Message` of the request; used to translate Ash field
      names into proto field names in `BadRequest` field violations.
    * `:domain` – `ErrorInfo.domain` (default `config :ash_grpc, :error_domain` or `"ash"`).
  """
  @spec to_rpc_error(Ash.Error.t() | term(), Keyword.t()) :: GRPC.RPCError.t()
  def to_rpc_error(error, opts \\ [])

  def to_rpc_error(%GRPC.RPCError{} = error, _opts), do: error

  def to_rpc_error(error, opts) do
    show? =
      Keyword.get_lazy(opts, :show_raised_errors?, fn ->
        Application.get_env(:ash_grpc, :show_raised_errors?, false)
      end)

    errors = flatten(error)
    infos = Enum.map(errors, &to_info/1)
    code = pick_code(infos)
    primary = Enum.find(infos, &(&1.code == code))
    names = field_names(opts[:message])

    details =
      [
        bad_request(infos, names),
        error_info(primary, opts),
        resource_info(primary),
        debug_info(errors, infos, show?)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Details.pack/1)

    %GRPC.RPCError{
      status: Info.status(code),
      message: status_message(code, infos, show?),
      details: details
    }
  end

  @doc """
  Converts a `GRPC.RPCError` (e.g. returned by a client stub) into an Ash error class.

  Options:

    * `:message` – the `IR.Message` of the request; used to translate proto field
      paths of `BadRequest` violations back into Ash field names.
    * `:resource` – resource for `Ash.Error.Query.NotFound`.
    * `:primary_key` – primary key for `Ash.Error.Query.NotFound`.
  """
  @spec from_rpc_error(GRPC.RPCError.t(), Keyword.t()) :: Exception.t()
  def from_rpc_error(%GRPC.RPCError{} = rpc_error, opts \\ []) do
    details = Details.unpack_all(rpc_error.details)
    code = Info.code(rpc_error.status || 2)

    code
    |> remote_errors(rpc_error, details, opts)
    |> Ash.Error.to_error_class()
  end

  ## Ash → gRPC

  defp flatten(%struct{errors: errors}) when struct in @class_modules,
    do: errors |> List.wrap() |> Enum.flat_map(&flatten/1) |> non_empty(struct)

  defp flatten(%struct{errors: errors})
       when struct in [Ash.Changeset, Ash.Query, Ash.ActionInput],
       do: errors |> List.wrap() |> Enum.flat_map(&flatten/1)

  defp flatten(errors) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)

  defp flatten(error) when is_exception(error), do: [error]

  defp flatten(other),
    do: other |> Ash.Error.to_ash_error() |> List.wrap() |> Enum.flat_map(&flatten/1)

  # an empty class still has a class
  defp non_empty([], struct), do: [struct.exception(errors: [])]
  defp non_empty(errors, _struct), do: errors

  defp to_info(error) do
    case AshGrpc.ToStatus.to_status(error) do
      %Info{} = info -> info
      _ -> %Info{code: :internal, message: nil, reason: "INTERNAL"}
    end
  rescue
    _ -> %Info{code: :internal, message: nil, reason: "INTERNAL"}
  end

  defp pick_code([]), do: :internal

  defp pick_code(infos) do
    codes = Enum.map(infos, & &1.code)
    Enum.find(@precedence, :internal, &(&1 in codes))
  end

  defp status_message(code, infos, show?) do
    infos
    |> Enum.filter(&(&1.code == code))
    |> Enum.map(fn info -> if info.public? or show?, do: info.message end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> case do
      [] -> Map.get(@generic_messages, code, Naming.snake(code) |> String.replace("_", " "))
      messages -> Enum.join(messages, "; ")
    end
  end

  defp bad_request(infos, names) do
    infos
    |> Enum.flat_map(& &1.field_violations)
    |> Enum.map(fn violation ->
      %Google.Rpc.BadRequest.FieldViolation{
        field: field_path(violation.path, names),
        description: violation.description || "",
        reason: Map.get(violation, :reason) || ""
      }
    end)
    |> Enum.uniq()
    |> case do
      [] -> nil
      violations -> %Google.Rpc.BadRequest{field_violations: violations}
    end
  end

  defp error_info(%Info{} = info, opts) do
    %Google.Rpc.ErrorInfo{
      reason: info.reason || Naming.constant(info.code),
      domain:
        Keyword.get_lazy(opts, :domain, fn ->
          Application.get_env(:ash_grpc, :error_domain, "ash")
        end),
      metadata: Map.new(info.metadata || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
    }
  end

  defp error_info(nil, _opts), do: nil

  defp resource_info(%Info{resource_info: info}) when is_map(info) do
    %Google.Rpc.ResourceInfo{
      resource_type: Map.get(info, :resource_type) || "",
      resource_name: Map.get(info, :resource_name) || "",
      owner: Map.get(info, :owner) || "",
      description: Map.get(info, :description) || ""
    }
  end

  defp resource_info(_), do: nil

  defp debug_info(_errors, _infos, false), do: nil

  defp debug_info(errors, infos, true) do
    hidden =
      errors
      |> Enum.zip(infos)
      |> Enum.reject(fn {_error, info} -> info.public? end)

    case hidden do
      [] ->
        nil

      hidden ->
        %Google.Rpc.DebugInfo{
          detail: Enum.map_join(hidden, "\n", fn {error, _} -> safe_message(error) end),
          stack_entries:
            Enum.flat_map(hidden, fn {error, _} ->
              case Map.get(error, :stacktrace) do
                %{stacktrace: stacktrace} when is_list(stacktrace) ->
                  Enum.map(stacktrace, &Exception.format_stacktrace_entry/1)

                _ ->
                  []
              end
            end)
        }
    end
  end

  defp safe_message(error) do
    Exception.message(error)
  rescue
    _ -> inspect(error.__struct__)
  end

  # `[:address, :lines, 0, :text]` → `"address.lines[0].text"`
  defp field_path(path, names) do
    path
    |> Enum.with_index()
    |> Enum.reduce("", fn
      {index, _}, acc when is_integer(index) ->
        acc <> "[#{index}]"

      {segment, 0}, _acc ->
        Map.get(names, segment) || Naming.snake(segment)

      {segment, _}, acc ->
        acc <> "." <> Naming.snake(segment)
    end)
  end

  # Ash name => proto field name, from the request message's field sources
  defp field_names(nil), do: %{}

  defp field_names(%IR.Message{fields: fields}) do
    fields
    |> Enum.flat_map(fn field ->
      case source_name(field.source) do
        nil -> []
        name -> [{name, field.name}]
      end
    end)
    |> Map.new()
  end

  # shapes emitted by `AshGrpc.Schema` (matched before the generic `{kind, name, type, c}`)
  defp source_name({:argument, resource, action, name})
       when is_atom(resource) and is_atom(action) and is_atom(name) and not is_nil(name),
       do: name

  defp source_name({kind, resource, name})
       when kind in [:attribute, :calculation, :aggregate, :relationship] and is_atom(resource) and
              is_atom(name),
       do: name

  defp source_name({_kind, name, _type, _constraints}) when is_atom(name), do: name
  defp source_name({_kind, name}) when is_atom(name), do: name
  defp source_name(name) when is_atom(name) and not is_nil(name), do: name
  defp source_name(_), do: nil

  ## gRPC → Ash

  defp proto_names(message), do: message |> field_names() |> Map.new(fn {k, v} -> {v, k} end)

  defp violation_error(%Google.Rpc.BadRequest.FieldViolation{} = violation, names) do
    {path, field} = parse_path(violation.field, names)

    Ash.Error.Changes.InvalidAttribute.exception(
      field: field,
      path: path,
      message: if(violation.description == "", do: "is invalid", else: violation.description)
    )
  end

  defp remote_errors(:not_found, _rpc_error, details, opts),
    do: [Ash.Error.Query.NotFound.exception(not_found_opts(opts, find(details, ResourceInfo)))]

  defp remote_errors(code, rpc_error, details, opts) when code in @invalid_codes do
    case Enum.flat_map(all(details, BadRequest), & &1.field_violations) do
      [] ->
        [remote_error(code, rpc_error, details, :invalid)]

      violations ->
        names = proto_names(opts[:message])
        Enum.map(violations, &violation_error(&1, names))
    end
  end

  defp remote_errors(code, rpc_error, details, _opts) when code in @forbidden_codes,
    do: [remote_error(code, rpc_error, details, :forbidden)]

  defp remote_errors(code, rpc_error, details, _opts),
    do: [remote_error(code, rpc_error, details, :unknown)]

  defp remote_error(code, rpc_error, details, class) do
    error_info = find(details, ErrorInfo) || %ErrorInfo{reason: nil, domain: nil}

    RemoteError.exception(
      code: code,
      status: rpc_error.status,
      message: rpc_error.message,
      reason: error_info.reason,
      domain: error_info.domain,
      metadata: error_info.metadata || %{},
      resource_info: resource_info_map(find(details, ResourceInfo)),
      details: details,
      class: class
    )
  end

  defp find(details, module), do: Enum.find(details, &is_struct(&1, module))
  defp all(details, module), do: Enum.filter(details, &is_struct(&1, module))

  # Wire data: segments become atoms only if they already exist
  defp parse_path("", _names), do: {[], nil}

  defp parse_path(path, names) do
    segments =
      path
      |> String.split(".")
      |> Enum.flat_map(&parse_segment/1)
      |> Enum.reject(&(&1 == ""))

    segments =
      case segments do
        [first | rest] when is_binary(first) -> [Map.get(names, first, first) | rest]
        segments -> segments
      end
      |> Enum.map(&existing_atom/1)

    case Enum.split(segments, -1) do
      {path, [field]} when not is_integer(field) -> {path, field}
      _ -> {segments, nil}
    end
  end

  # `"lines[0][1]"` → `["lines", 0, 1]`
  defp parse_segment(segment) do
    case Regex.run(~r/^([^\[]*)((?:\[\d+\])*)$/, segment) do
      [_, name, indices] ->
        indices =
          ~r/\[(\d+)\]/
          |> Regex.scan(indices)
          |> Enum.map(fn [_, index] -> String.to_integer(index) end)

        [name | indices]

      _ ->
        [segment]
    end
  end

  defp existing_atom(segment) when is_binary(segment) do
    String.to_existing_atom(segment)
  rescue
    ArgumentError -> segment
  end

  defp existing_atom(segment), do: segment

  defp not_found_opts(opts, resource_info) do
    [
      resource: opts[:resource],
      primary_key: opts[:primary_key] || (resource_info && blank(resource_info.resource_name))
    ]
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  defp resource_info_map(nil), do: nil

  defp resource_info_map(%ResourceInfo{} = info) do
    %{
      resource_type: info.resource_type,
      resource_name: info.resource_name,
      owner: info.owner,
      description: info.description
    }
  end
end
