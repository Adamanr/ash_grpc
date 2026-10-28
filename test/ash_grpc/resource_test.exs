defmodule AshGrpc.ResourceTest do
  use ExUnit.Case, async: true

  import AshGrpc.Test.DslHelpers

  alias AshGrpc.Resource.Info
  alias AshGrpc.Test.{Address, Post, Profile, User}

  describe "Info" do
    test "message names" do
      assert Info.message_name(User) == "User"
      assert Info.message_name(Post) == "Post"
      assert Info.message_name(Profile) == "UserProfile"
      assert Info.message_name(Address) == "Address"
    end

    test "grpc?/1" do
      assert Info.grpc?(User)
      assert Info.grpc?(Profile)
      refute Info.grpc?(Address)
      refute Info.grpc?(String)
    end

    test "fields default to public attributes" do
      assert Info.field_names(Post) == [:id, :title, :published_at, :user_id]
      assert Info.field_names(Address) == [:street, :city]
    end

    test "fields resolve kinds, types and tuning" do
      fields = Map.new(Info.fields(User), &{&1.name, &1})

      assert %{kind: :attribute, proto_name: "id", config: %{number: 1}} = fields.id
      assert %{kind: :attribute, allow_nil?: false} = fields.email
      assert %{kind: :attribute, allow_nil?: true, config: nil} = fields.secret
      assert %{kind: :calculation, type: Ash.Type.String} = fields.display_name
      assert %{kind: :calculation, proto_name: "is_adult"} = fields.adult?
      assert %{kind: :aggregate, type: Ash.Type.Integer, allow_nil?: false} = fields.posts_count
      assert %{kind: :relationship, type: Post, cardinality: :many} = fields.posts
      assert %{config: %{representation: {:message, "google.protobuf.Value"}}} = fields.payload
      assert %{config: %{json_name: "emailAddress", doc: "Primary email"}} = fields.email

      assert %{config: %{deprecated?: true, options: [{"(my.ext).sensitive", true}]}} =
               fields.name
    end

    test "embedded resource tuning" do
      assert [%{name: :bio}, %{name: :home}, %{name: :private_note, proto_name: "note"}] =
               Info.fields(Profile)
    end

    test "reserved" do
      assert Info.reserved_numbers(User) == [5, {10, 12}, {100, :max}]
      assert Info.reserved_names(User) == ["legacy_name"]
    end

    test "default_load lists calculations and aggregates" do
      assert Info.default_load(User) == [:display_name, :adult?, :posts_count]
    end

    test "rpc kinds and get_by are resolved" do
      kinds = Map.new(Info.rpcs(User), &{&1.name, {&1.kind, &1.get_by}})

      assert kinds.get_user == {:get, [:id]}
      assert kinds.get_user_by_email == {:get, []}
      assert kinds.list_users == {:list, []}
      assert kinds.watch_users == {:server_stream, []}
      assert kinds.create_user == {:create, []}
      assert kinds.import_users == {:client_stream, []}
      assert kinds.update_user == {:update, []}
      assert kinds.delete_user == {:destroy, []}
      assert kinds.ping == {:action, []}
      assert kinds.sync == {:bidi_stream, []}

      assert {:get, [:id]} =
               AshGrpc.Test.Product
               |> Info.rpc(:get_product)
               |> Map.take([:kind, :get_by])
               |> then(&{&1.kind, &1.get_by})
    end

    test "rpc options are kept" do
      rpc = Info.rpc(User, :get_user)
      assert rpc.read_mask?
      assert rpc.load == [:posts]
      assert %{input: :wrapped} = Info.rpc(User, :create_user_wrapped)
      assert %{handler: AshGrpc.Test.SyncHandler} = Info.rpc(User, :sync)

      assert %{service: "ExportService", response_message: "EmailList"} =
               Info.rpc(User, :list_emails)
    end
  end

  describe "field verifier" do
    test "unknown and duplicated fields" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.UnknownField do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            grpc do
              fields [:id, :nope, :id]
            end
          end
        end

      assert Enum.any?(
               messages,
               &(&1 =~ ":nope is not an attribute, calculation, aggregate or relationship")
             )

      assert Enum.any?(messages, &(&1 =~ "field :id is listed more than once"))
    end

    test "field entity must be part of the message" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.FieldNotInMessage do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
              attribute :hidden, :string
            end

            grpc do
              field :hidden, number: 2
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "field :hidden is not part of the message"))
    end

    test "invalid, duplicate and reserved proto names" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.BadNames do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id, public?: true
              attribute :a, :string, public?: true
              attribute :b, :string, public?: true
              attribute :c, :string, public?: true
              attribute :old, :string, public?: true
            end

            grpc do
              field :a, proto_name: "bad-name"
              field :c, proto_name: "b"
              reserved names: ["old"]
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ ~s("bad-name" is not a valid proto field name)))
      assert Enum.any?(messages, &(&1 =~ ~s(proto field name "b" is used by [:b, :c])))
      assert Enum.any?(messages, &(&1 =~ ~s(proto field name "old" is reserved)))
    end

    test "invalid numbers" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.BadNumbers do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id, public?: true
              attribute :a, :string, public?: true
              attribute :b, :string, public?: true
              attribute :c, :string, public?: true
              attribute :d, :string, public?: true
              attribute :e, :string, public?: true
            end

            grpc do
              field :id, number: 1
              field :a, number: 1
              field :b, number: 19_500
              field :c, number: 536_870_912
              field :d, number: 7
              field :e, number: 8
              reserved numbers: [7, 0, :x]
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "field number 1 is used by [:id, :a]"))
      assert Enum.any?(messages, &(&1 =~ "field number 19500 is in 19000..19999"))
      assert Enum.any?(messages, &(&1 =~ "field number 536870912 is above the maximum"))
      assert Enum.any?(messages, &(&1 =~ "field number 7 is reserved"))
      assert Enum.any?(messages, &(&1 =~ "invalid reserved number 0"))
      assert Enum.any?(messages, &(&1 =~ "invalid reserved number :x"))
      refute Enum.any?(messages, &(&1 =~ "field number 8"))
    end

    test "relationship destination must use AshGrpc.Resource" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.Plain do
            use Ash.Resource

            attributes do
              uuid_primary_key :id
            end
          end

          defmodule Elixir.AshGrpc.Test.Fixtures.WithPlainRelationship do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            relationships do
              belongs_to :plain, AshGrpc.Test.Fixtures.Plain
            end

            grpc do
              fields [:id, :plain]
            end
          end
        end

      assert Enum.any?(
               messages,
               &(&1 =~
                   "points to AshGrpc.Test.Fixtures.Plain, which does not use the AshGrpc.Resource extension")
             )
    end

    test "unsupported types need a representation" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.TermField do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id, public?: true
              attribute :blob, :term, public?: true
              attribute :ok_blob, :term, public?: true
            end

            grpc do
              field :ok_blob, representation: {:message, "google.protobuf.Value"}
            end
          end
        end

      assert [message] = messages
      assert message =~ "grpc -> fields -> blob"
      assert message =~ "Ash.Type.Term has no protobuf mapping"
      assert message =~ "Set `representation:`"
    end
  end

  describe "rpc verifier" do
    test "action must exist and fit the kind" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.BadActions do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read, :create]
            end

            grpc do
              rpc :missing, :nope
              rpc :get_created, :create, kind: :get
              rpc :stream_create, :read, kind: :client_stream
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "action :nope does not exist"))

      assert Enum.any?(
               messages,
               &(&1 =~ "rpc kind :get requires a :read action, but :create is a :create action")
             )

      assert Enum.any?(
               messages,
               &(&1 =~
                   "rpc kind :client_stream requires a :create action, but :read is a :read action")
             )
    end

    test "get_by and kind-specific options" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.BadOptions do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read, :create, :update, :destroy]
            end

            grpc do
              rpc :get_thing, :read, get_by: [:slug]
              rpc :list_things, :read, kind: :list, get_by: [:id]
              rpc :create_thing, :create, update_mask?: true, read_mask?: true
              rpc :get_other, :read, kind: :get, filter?: true
              rpc :update_thing, :update, return_destroyed?: true
              rpc :stream_things, :read, kind: :server_stream, input: :wrapped
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "get_by field :slug is neither an attribute"))

      assert Enum.any?(
               messages,
               &(&1 =~ "`get_by` is only supported for `kind: :get`, got :list")
             )

      assert Enum.any?(
               messages,
               &(&1 =~ "`update_mask?` is only supported for :update rpcs, got :create")
             )

      assert Enum.any?(
               messages,
               &(&1 =~ "`read_mask?` is only supported for :get, :list, :server_stream rpcs")
             )

      assert Enum.any?(messages, &(&1 =~ "`filter?` is only supported for :list rpcs, got :get"))

      assert Enum.any?(
               messages,
               &(&1 =~ "`return_destroyed?` is only supported for :destroy rpcs")
             )

      assert Enum.any?(
               messages,
               &(&1 =~ "`input: :wrapped` is only supported for :create, :update")
             )
    end

    test "bidi streaming requires a handler; handlers and messages must exist" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.BadStreaming do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end

            grpc do
              rpc :sync, :read, kind: :bidi_stream
              rpc :other, :read, handler: AshGrpc.Test.Fixtures.NoSuchHandler
              rpc :renamed, :read, request_message: "bad name"
              rpc :replaced, :read, response_message: String
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "`kind: :bidi_stream` requires a `handler` module"))

      assert Enum.any?(
               messages,
               &(&1 =~ "handler AshGrpc.Test.Fixtures.NoSuchHandler is not an available module")
             )

      assert Enum.any?(
               messages,
               &(&1 =~ ~s(`request_message` "bad name" must be a PascalCase message name))
             )

      assert Enum.any?(
               messages,
               &(&1 =~ "`response_message` String is not a protobuf message module")
             )
    end

    test "action inputs and returns need a mapping" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.BadInputs do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            actions do
              action :run, :term do
                argument :input, :function
                run fn _, _ -> {:ok, nil} end
              end
            end

            grpc do
              rpc :run, :run
            end
          end
        end

      assert Enum.any?(
               messages,
               &(&1 =~ "argument :input of action :run: Ash.Type.Function has no protobuf mapping")
             )

      assert Enum.any?(
               messages,
               &(&1 =~ "return type of action :run: Ash.Type.Term has no protobuf mapping")
             )
    end

    test "embedded resources cannot declare rpcs" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.EmbeddedRpc do
            use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]

            attributes do
              attribute :name, :string, public?: true
            end

            actions do
              defaults [:read]
            end

            grpc do
              rpc :list, :read
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "embedded resources cannot declare rpcs"))
    end

    test "valid resources produce no errors" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.Valid do
            use Ash.Resource, extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id, public?: true
            end

            actions do
              defaults [:read]
            end

            grpc do
              field :id, number: 1
              rpc :get_valid, :read, kind: :get
            end
          end
        end

      assert messages == []
    end
  end
end
