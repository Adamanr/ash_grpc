defmodule AshGrpc.ErrorTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Error
  alias AshGrpc.Error.{Details, Info, RemoteError}
  alias AshGrpc.Proto.IR
  alias Google.Rpc.{BadRequest, ErrorInfo, ResourceInfo}

  defp details(%GRPC.RPCError{details: details}), do: Details.unpack_all(details)

  defp detail(rpc_error, module), do: Enum.find(details(rpc_error), &is_struct(&1, module))

  defp invalid_attribute(opts), do: Ash.Error.Changes.InvalidAttribute.exception(opts)

  describe "to_rpc_error/2" do
    test "invalid input → INVALID_ARGUMENT with BadRequest field violations" do
      error =
        Ash.Error.to_error_class([
          invalid_attribute(
            field: :email,
            message: "must look like %{format}",
            vars: [format: "an email"]
          ),
          Ash.Error.Changes.Required.exception(field: :name, type: :attribute),
          invalid_attribute(field: :city, path: [:addresses, 0], message: "is too long")
        ])

      rpc_error = Error.to_rpc_error(error)

      assert rpc_error.status == GRPC.Status.invalid_argument()
      assert rpc_error.message =~ "email: must look like an email"
      assert rpc_error.message =~ "name: is required"

      assert %BadRequest{field_violations: violations} = detail(rpc_error, BadRequest)

      assert Enum.map(violations, &{&1.field, &1.description, &1.reason}) == [
               {"email", "must look like an email", "INVALID"},
               {"name", "is required", "REQUIRED"},
               {"addresses[0].city", "is too long", "INVALID"}
             ]

      assert %ErrorInfo{reason: "INVALID", domain: "ash", metadata: %{"field" => "email"}} =
               detail(rpc_error, ErrorInfo)
    end

    test "field paths use proto field names from the request message" do
      message = %IR.Message{
        name: "CreateUserRequest",
        full_name: "x.CreateUserRequest",
        fields: [
          %IR.Field{
            name: "email_address",
            number: 1,
            type: :string,
            source: {:attribute, :email}
          },
          %IR.Field{
            name: "nick",
            number: 2,
            type: :string,
            source: {:argument, :nickname, :string, []}
          }
        ]
      }

      rpc_error =
        Error.to_rpc_error(
          [
            invalid_attribute(field: :email),
            Ash.Error.Changes.InvalidArgument.exception(field: :nickname)
          ],
          message: message
        )

      assert %BadRequest{field_violations: [v1, v2]} = detail(rpc_error, BadRequest)
      assert v1.field == "email_address"
      assert v1.description == "is invalid"
      assert v2.field == "nick"
    end

    test "NOT_FOUND carries ResourceInfo" do
      error =
        Ash.Error.Query.NotFound.exception(
          resource: AshGrpc.Test.Types.Profile,
          primary_key: %{id: "abc"}
        )

      rpc_error = Error.to_rpc_error(error)
      assert rpc_error.status == GRPC.Status.not_found()
      assert rpc_error.message == "record with id: \"abc\" not found"

      assert %ResourceInfo{resource_type: "Profile", resource_name: "id=abc"} =
               detail(rpc_error, ResourceInfo)

      assert %ErrorInfo{reason: "NOT_FOUND", metadata: %{"resource" => "Profile"}} =
               detail(rpc_error, ErrorInfo)
    end

    test "NOT_FOUND wins over other invalid errors in the same class" do
      error =
        Ash.Error.to_error_class([
          invalid_attribute(field: :a),
          Ash.Error.Query.NotFound.exception([])
        ])

      assert Error.to_rpc_error(error).status == GRPC.Status.not_found()
    end

    test "forbidden → PERMISSION_DENIED without policy breakdown" do
      error = Ash.Error.Forbidden.exception(errors: [Ash.Error.Forbidden.Policy.exception([])])
      rpc_error = Error.to_rpc_error(error)

      assert rpc_error.status == GRPC.Status.permission_denied()
      assert rpc_error.message == "forbidden"
      assert %ErrorInfo{reason: "FORBIDDEN"} = detail(rpc_error, ErrorInfo)
      refute detail(rpc_error, BadRequest)
    end

    test "actor required → UNAUTHENTICATED" do
      for error <- [
            Ash.Error.Forbidden.DomainRequiresActor.exception(domain: Foo),
            Ash.Error.Changes.ActionRequiresActor.exception([]),
            AshGrpc.Error.Unauthenticated.exception([])
          ] do
        assert Error.to_rpc_error(error).status == GRPC.Status.unauthenticated()
      end
    end

    test "stale records → ABORTED, unique violations → ALREADY_EXISTS, timeouts → DEADLINE_EXCEEDED" do
      assert Error.to_rpc_error(Ash.Error.Changes.StaleRecord.exception([])).status ==
               GRPC.Status.aborted()

      unique =
        invalid_attribute(
          field: :email,
          message: "has already been taken",
          private_vars: [constraint: "users_email_index", constraint_type: :unique]
        )

      rpc_error = Error.to_rpc_error(Ash.Error.to_error_class(unique))
      assert rpc_error.status == GRPC.Status.already_exists()
      assert %BadRequest{field_violations: [%{field: "email"}]} = detail(rpc_error, BadRequest)
      refute inspect(details(rpc_error)) =~ "users_email_index"

      assert Error.to_rpc_error(Ash.Error.Invalid.Timeout.exception(name: :x, timeout: 10)).status ==
               GRPC.Status.deadline_exceeded()
    end

    test "unknown errors → INTERNAL, message hidden" do
      for error <- [
            %RuntimeError{message: "secret db password"},
            Ash.Error.Unknown.UnknownError.exception(error: "secret db password"),
            Ash.Error.to_error_class(%RuntimeError{message: "secret db password"}),
            "secret db password",
            {:error, :secret}
          ] do
        rpc_error = Error.to_rpc_error(error, show_raised_errors?: false)
        assert rpc_error.status == GRPC.Status.internal(), inspect(error)
        assert rpc_error.message == "internal error"
        refute inspect(details(rpc_error)) =~ "secret"
        assert %ErrorInfo{reason: "INTERNAL"} = detail(rpc_error, ErrorInfo)
      end
    end

    test "show_raised_errors? reveals messages and adds DebugInfo" do
      rpc_error = Error.to_rpc_error(%RuntimeError{message: "boom"}, show_raised_errors?: true)
      assert rpc_error.message == "boom"
      assert %Google.Rpc.DebugInfo{detail: "boom"} = detail(rpc_error, Google.Rpc.DebugInfo)
    end

    test "show_raised_errors? defaults to the application env" do
      Application.put_env(:ash_grpc, :show_raised_errors?, true)

      try do
        assert Error.to_rpc_error(%RuntimeError{message: "boom"}).message == "boom"
      after
        Application.delete_env(:ash_grpc, :show_raised_errors?)
      end
    end

    test "invalid errors without an implementation hide their message" do
      error = Ash.Error.Query.InvalidFilterValue.exception(value: "x", message: "internal detail")
      rpc_error = Error.to_rpc_error(error)
      assert rpc_error.status == GRPC.Status.invalid_argument()
      assert rpc_error.message == "invalid request"
    end

    test "known invalid errors" do
      assert %{status: 3, message: "invalid primary key"} =
               Error.to_rpc_error(Ash.Error.Invalid.InvalidPrimaryKey.exception(value: 1))

      assert %{status: 3} =
               rpc_error =
               Error.to_rpc_error(
                 Ash.Error.Invalid.NoSuchInput.exception(input: "nope", inputs: [])
               )

      assert %BadRequest{field_violations: [%{field: "nope"}]} = detail(rpc_error, BadRequest)

      rpc_error =
        Error.to_rpc_error(
          Ash.Error.Changes.InvalidChanges.exception(fields: [:a, :b], message: "conflict")
        )

      assert %BadRequest{field_violations: [%{field: "a"}, %{field: "b"}]} =
               detail(rpc_error, BadRequest)

      assert %{status: 3} = Error.to_rpc_error(Ash.Error.Page.InvalidKeyset.exception([]))
      assert %{status: 3} = Error.to_rpc_error(Ash.Error.Invalid.TenantRequired.exception([]))

      assert %{status: 3} =
               Error.to_rpc_error(
                 Ash.Error.Changes.InvalidRelationship.exception(
                   relationship: :posts,
                   message: "bad"
                 )
               )
    end

    test "changesets and lists are flattened" do
      changeset = %Ash.Changeset{errors: [invalid_attribute(field: :a)]}
      assert Error.to_rpc_error(changeset).status == GRPC.Status.invalid_argument()
      assert Error.to_rpc_error([invalid_attribute(field: :a)]).status == 3
    end

    test "empty classes keep their class" do
      assert Error.to_rpc_error(Ash.Error.Invalid.exception(errors: [])).status == 3
      assert Error.to_rpc_error(Ash.Error.Forbidden.exception(errors: [])).status == 7
    end

    test "GRPC.RPCError passes through" do
      error = GRPC.RPCError.exception(status: :unavailable, message: "down")
      assert Error.to_rpc_error(error) == error
    end

    test "the domain is configurable" do
      rpc_error = Error.to_rpc_error(invalid_attribute(field: :a), domain: "example.com")
      assert %ErrorInfo{domain: "example.com"} = detail(rpc_error, ErrorInfo)
    end

    test "details survive the grpc-status-details-bin trailer encoding" do
      rpc_error = Error.to_rpc_error(invalid_attribute(field: :email, message: "bad"))

      trailers =
        GRPC.Transport.HTTP2.server_trailers(
          rpc_error.status,
          rpc_error.message,
          rpc_error.details
        )

      decoded =
        GRPC.RPCError.from_grpc_status_details_bin(%{
          status: rpc_error.status,
          message: rpc_error.message,
          encoded_details_bin: trailers["grpc-status-details-bin"]
        })

      assert decoded.details == rpc_error.details

      assert %BadRequest{field_violations: [%{field: "email", description: "bad"}]} =
               detail(decoded, BadRequest)
    end
  end

  describe "AshGrpc.ToStatus" do
    defmodule CustomError do
      defexception [:limit]
      def message(_), do: "quota"
    end

    defimpl AshGrpc.ToStatus, for: CustomError do
      def to_status(error) do
        %AshGrpc.Error.Info{
          code: :resource_exhausted,
          message: "quota exceeded",
          public?: true,
          reason: "QUOTA",
          metadata: %{limit: error.limit}
        }
      end
    end

    test "custom implementations" do
      rpc_error = Error.to_rpc_error(%CustomError{limit: 5})
      assert rpc_error.status == GRPC.Status.resource_exhausted()
      assert rpc_error.message == "quota exceeded"

      assert %ErrorInfo{reason: "QUOTA", metadata: %{"limit" => "5"}} =
               detail(rpc_error, ErrorInfo)
    end

    test "fallback by class" do
      assert %Info{code: :invalid_argument, public?: false} =
               AshGrpc.ToStatus.to_status(Ash.Error.Query.InvalidLimit.exception(limit: -1))

      assert %Info{code: :permission_denied} =
               AshGrpc.ToStatus.to_status(Ash.Error.Forbidden.CannotFilterCreates.exception([]))

      assert %Info{code: :internal} = AshGrpc.ToStatus.to_status(%ArgumentError{})
    end
  end

  describe "from_rpc_error/2" do
    defp roundtrip(error, opts \\ []),
      do: error |> Error.to_rpc_error(opts) |> Error.from_rpc_error(opts)

    test "BadRequest → Ash.Error.Invalid with InvalidAttribute per violation" do
      error =
        Ash.Error.to_error_class([
          invalid_attribute(field: :email, message: "is invalid"),
          invalid_attribute(field: :city, path: [:addresses, 0], message: "too long")
        ])

      assert %Ash.Error.Invalid{errors: [email, city]} = roundtrip(error)

      assert %Ash.Error.Changes.InvalidAttribute{field: :email, path: [], message: "is invalid"} =
               email

      assert %Ash.Error.Changes.InvalidAttribute{
               field: :city,
               path: [:addresses, 0],
               message: "too long"
             } = city
    end

    test "proto field names are mapped back to Ash names" do
      message = %IR.Message{
        name: "R",
        full_name: "x.R",
        fields: [
          %IR.Field{name: "email_address", number: 1, type: :string, source: {:attribute, :email}}
        ]
      }

      assert %Ash.Error.Invalid{errors: [%{field: :email}]} =
               roundtrip(invalid_attribute(field: :email), message: message)
    end

    test "unknown field names never become atoms" do
      name = "field_#{System.unique_integer([:positive])}"

      rpc_error = %GRPC.RPCError{
        status: 3,
        message: "bad",
        details: [
          Details.pack(%BadRequest{
            field_violations: [%BadRequest.FieldViolation{field: "a.#{name}", description: ""}]
          })
        ]
      }

      assert %Ash.Error.Invalid{errors: [%{field: ^name, path: [:a], message: "is invalid"}]} =
               Error.from_rpc_error(rpc_error)
    end

    test "NOT_FOUND → Ash.Error.Query.NotFound" do
      error = Ash.Error.Query.NotFound.exception(primary_key: %{id: 1})

      assert %Ash.Error.Invalid{
               errors: [%Ash.Error.Query.NotFound{primary_key: "id=1", resource: Foo}]
             } =
               roundtrip(error, resource: Foo)
    end

    test "PERMISSION_DENIED / UNAUTHENTICATED → Ash.Error.Forbidden" do
      assert %Ash.Error.Forbidden{
               errors: [%RemoteError{code: :permission_denied, reason: "FORBIDDEN"}]
             } =
               roundtrip(Ash.Error.Forbidden.Policy.exception([]))

      assert %Ash.Error.Forbidden{errors: [%RemoteError{code: :unauthenticated}]} =
               roundtrip(AshGrpc.Error.Unauthenticated.exception([]))
    end

    test "invalid statuses without violations → Ash.Error.Invalid" do
      assert %Ash.Error.Invalid{errors: [%RemoteError{code: :aborted, class: :invalid}]} =
               roundtrip(Ash.Error.Changes.StaleRecord.exception([]))
    end

    test "other statuses → Ash.Error.Unknown with status info" do
      rpc_error = GRPC.RPCError.exception(status: :unavailable, message: "down")

      assert %Ash.Error.Unknown{
               errors: [%RemoteError{code: :unavailable, status: 14, message: "down"} = remote]
             } = Error.from_rpc_error(rpc_error)

      assert Exception.message(remote) =~ "unavailable"

      assert %Ash.Error.Unknown{
               errors: [%RemoteError{code: :internal, domain: "ash", reason: "INTERNAL"}]
             } =
               roundtrip(%RuntimeError{message: "x"})
    end

    test "unknown details are kept as Any" do
      any = %Google.Protobuf.Any{type_url: "type.googleapis.com/x.Custom", value: <<1, 2>>}

      bad = %Google.Protobuf.Any{
        type_url: "type.googleapis.com/google.rpc.ErrorInfo",
        value: <<255>>
      }

      assert %Ash.Error.Unknown{errors: [%RemoteError{details: [^any, ^bad]}]} =
               Error.from_rpc_error(%GRPC.RPCError{status: 2, message: "x", details: [any, bad]})
    end

    test "remote errors convert back to the same status" do
      remote =
        Error.from_rpc_error(
          GRPC.RPCError.exception(status: :resource_exhausted, message: "slow down")
        )

      assert %{status: 8, message: "slow down"} = Error.to_rpc_error(remote)
    end
  end
end
