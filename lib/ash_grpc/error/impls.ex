# `AshGrpc.ToStatus` implementations for core Ash errors (see `AshGrpc.Error`).

alias AshGrpc.Error.{Helpers, Info}

for module <- [
      Ash.Error.Changes.InvalidAttribute,
      Ash.Error.Changes.InvalidArgument,
      Ash.Error.Action.InvalidArgument,
      Ash.Error.Query.InvalidArgument,
      Ash.Error.Query.InvalidCalculationArgument
    ] do
  defimpl AshGrpc.ToStatus, for: module do
    def to_status(error) do
      field = Map.get(error, :field)
      description = Helpers.description(error, "is invalid")

      {code, reason} =
        if unique?(error),
          do: {:already_exists, "ALREADY_EXISTS"},
          else: {:invalid_argument, "INVALID"}

      %Info{
        code: code,
        message: field_message(field, description),
        public?: true,
        reason: reason,
        metadata: field_metadata(field),
        field_violations: [
          %{path: Helpers.path(error, field), description: description, reason: reason}
        ]
      }
    end

    # data layers report unique constraint violations as invalid attributes
    # not every error struct has `private_vars`, hence the dynamic lookup
    defp unique?(error) do
      case Map.get(error, :private_vars) do
        private_vars when is_list(private_vars) -> private_vars[:constraint_type] == :unique
        _ -> false
      end
    end

    defp field_message(nil, description), do: description
    defp field_message(field, description), do: "#{field}: #{description}"

    defp field_metadata(nil), do: %{}
    defp field_metadata(field), do: %{"field" => to_string(field)}
  end
end

for module <- [Ash.Error.Changes.Required, Ash.Error.Query.Required] do
  defimpl AshGrpc.ToStatus, for: module do
    def to_status(error) do
      %Info{
        code: :invalid_argument,
        message: "#{error.field}: is required",
        public?: true,
        reason: "REQUIRED",
        metadata: %{"field" => to_string(error.field)},
        field_violations: [
          %{
            path: Helpers.path(error, error.field),
            description: "is required",
            reason: "REQUIRED"
          }
        ]
      }
    end
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Changes.InvalidChanges do
  def to_status(error) do
    description = Helpers.description(error, "is invalid")
    fields = List.wrap(error.fields)

    %Info{
      code: :invalid_argument,
      message:
        if(fields == [], do: description, else: "#{Enum.join(fields, ", ")}: #{description}"),
      public?: true,
      reason: "INVALID",
      field_violations:
        Enum.map(fields, fn field ->
          %{path: Helpers.path(error, field), description: description, reason: "INVALID"}
        end)
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Changes.InvalidRelationship do
  def to_status(error) do
    description = Helpers.description(error, "is invalid")

    %Info{
      code: :invalid_argument,
      message: "#{error.relationship}: #{description}",
      public?: true,
      reason: "INVALID",
      field_violations: [
        %{
          path: Helpers.path(error, error.relationship),
          description: description,
          reason: "INVALID"
        }
      ]
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Invalid.NoSuchInput do
  def to_status(error) do
    %Info{
      code: :invalid_argument,
      message: "#{error.input}: no such input",
      public?: true,
      reason: "NO_SUCH_INPUT",
      field_violations: [
        %{
          path: Helpers.path(error, error.input),
          description: "no such input",
          reason: "NO_SUCH_INPUT"
        }
      ]
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Changes.NoSuchAttribute do
  def to_status(error) do
    %Info{
      code: :invalid_argument,
      message: "#{error.attribute}: no such attribute",
      public?: true,
      reason: "NO_SUCH_INPUT",
      field_violations: [
        %{
          path: Helpers.path(error, error.attribute),
          description: "no such attribute",
          reason: "NO_SUCH_INPUT"
        }
      ]
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Invalid.InvalidPrimaryKey do
  def to_status(_error) do
    %Info{
      code: :invalid_argument,
      message: "invalid primary key",
      public?: true,
      reason: "INVALID_PRIMARY_KEY"
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Page.InvalidKeyset do
  def to_status(_error) do
    %Info{
      code: :invalid_argument,
      message: "invalid page token",
      public?: true,
      reason: "INVALID_PAGE_TOKEN",
      field_violations: [
        %{path: ["page_token"], description: "is invalid", reason: "INVALID_PAGE_TOKEN"}
      ]
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Invalid.TenantRequired do
  def to_status(error) do
    %Info{
      code: :invalid_argument,
      message: "tenant required",
      public?: true,
      reason: "TENANT_REQUIRED",
      metadata: resource_metadata(error.resource)
    }
  end

  defp resource_metadata(resource) do
    case Helpers.resource_name(resource) do
      nil -> %{}
      name -> %{"resource" => name}
    end
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Query.NotFound do
  def to_status(error) do
    resource = Helpers.resource_name(error.resource)

    %Info{
      code: :not_found,
      message: message(error),
      public?: true,
      reason: "NOT_FOUND",
      metadata: if(resource, do: %{"resource" => resource}, else: %{}),
      resource_info: %{
        resource_type: resource || "",
        resource_name: resource_name(error.primary_key),
        description: "not found"
      }
    }
  end

  defp message(%{primary_key: key} = error) when is_map(key) and not is_struct(key),
    do: Exception.message(error)

  defp message(_error), do: "record not found"

  defp resource_name(key) when is_map(key) and not is_struct(key) do
    key
    |> Enum.sort()
    |> Enum.map_join(",", fn {field, value} -> "#{field}=#{value_to_string(value)}" end)
  end

  defp resource_name(_), do: ""

  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp value_to_string(value), do: inspect(value)
end

for module <- [Ash.Error.Forbidden.Policy, Ash.Error.Forbidden.Placeholder] do
  defimpl AshGrpc.ToStatus, for: module do
    # no policy breakdown over the wire
    def to_status(_error) do
      %Info{code: :permission_denied, message: "forbidden", public?: true, reason: "FORBIDDEN"}
    end
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Forbidden.ForbiddenField do
  def to_status(error) do
    %Info{
      code: :permission_denied,
      message: "forbidden field",
      public?: true,
      reason: "FORBIDDEN_FIELD",
      metadata: if(error.field, do: %{"field" => to_string(error.field)}, else: %{})
    }
  end
end

for module <- [
      Ash.Error.Forbidden.DomainRequiresActor,
      Ash.Error.Changes.ActionRequiresActor,
      Ash.Error.Query.ReadActionRequiresActor
    ] do
  defimpl AshGrpc.ToStatus, for: module do
    def to_status(_error) do
      %Info{
        code: :unauthenticated,
        message: "authentication required",
        public?: true,
        reason: "ACTOR_REQUIRED"
      }
    end
  end
end

defimpl AshGrpc.ToStatus, for: AshGrpc.Error.Unauthenticated do
  def to_status(error) do
    %Info{
      code: :unauthenticated,
      message: error.message || "unauthenticated",
      public?: true,
      reason: "UNAUTHENTICATED"
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Changes.StaleRecord do
  def to_status(error) do
    resource = Helpers.resource_name(error.resource)

    %Info{
      code: :aborted,
      message: "stale record",
      public?: true,
      reason: "STALE_RECORD",
      metadata: if(resource, do: %{"resource" => resource}, else: %{})
    }
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Invalid.Timeout do
  def to_status(_error) do
    %Info{code: :deadline_exceeded, message: "timeout", public?: true, reason: "TIMEOUT"}
  end
end

defimpl AshGrpc.ToStatus, for: Ash.Error.Invalid.Unavailable do
  def to_status(error) do
    %Info{code: :unavailable, message: Helpers.message(error), reason: "UNAVAILABLE"}
  end
end

defimpl AshGrpc.ToStatus, for: AshGrpc.Error.RemoteError do
  def to_status(error) do
    code = if error.code in AshGrpc.Error.Info.codes(), do: error.code, else: :unknown

    %Info{
      code: code,
      message: error.message,
      public?: code not in [:internal, :unknown, :data_loss],
      reason: error.reason || "REMOTE_ERROR",
      metadata: error.metadata || %{}
    }
  end
end

defimpl AshGrpc.ToStatus, for: GRPC.RPCError do
  def to_status(error) do
    code = Info.code(error.status || 2)
    code = if code == :ok, do: :unknown, else: code

    %Info{
      code: code,
      message: error.message,
      public?: code not in [:internal, :unknown, :data_loss],
      reason: Atom.to_string(code) |> String.upcase()
    }
  end
end
