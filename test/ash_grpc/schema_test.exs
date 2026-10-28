defmodule AshGrpc.SchemaTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.{IR, Lock}
  alias AshGrpc.Schema
  alias AshGrpc.Test.{Accounts, Address, Catalog, Product, Profile, User}

  @accounts "ashgrpc.test.accounts.v1"
  @catalog "ashgrpc.test.catalog.v1"

  doctest AshGrpc.Schema.Naming

  setup_all do
    {:ok, schema} = Schema.build([Accounts, Catalog])
    [accounts, catalog] = schema.files
    %{schema: schema, accounts: accounts, catalog: catalog}
  end

  defp message(schema, name) do
    {:ok, %IR.Message{} = message} = IR.Schema.lookup(schema, name)
    message
  end

  defp field(message, name), do: Enum.find(message.fields, &(&1.name == name))
  defp field_names(message), do: Enum.map(message.fields, & &1.name)

  defp rpc(file, name) do
    Enum.find_value(file.services, fn service -> Enum.find(service.rpcs, &(&1.name == name)) end)
  end

  describe "files" do
    test "one file per domain", %{accounts: accounts, catalog: catalog} do
      assert %IR.File{
               path: "ashgrpc/test/accounts/v1/accounts.proto",
               package: @accounts,
               doc: "Accounts API",
               source: {:domain, Accounts},
               syntax: :proto3,
               options: [
                 %IR.Option{name: "go_package", value: "example.com/gen/accounts/v1;accountsv1"},
                 %IR.Option{name: "java_multiple_files", value: true}
               ]
             } = accounts

      assert %IR.File{
               path: "ashgrpc/test/catalog/v1/catalog.proto",
               package: @catalog,
               source: {:domain, Catalog},
               options: []
             } = catalog
    end

    test "imports are collected, deduplicated and sorted", %{accounts: accounts, catalog: catalog} do
      assert accounts.imports == [
               "google/api/annotations.proto",
               "google/protobuf/empty.proto",
               "google/protobuf/field_mask.proto",
               "google/protobuf/struct.proto",
               "google/protobuf/timestamp.proto",
               "google/rpc/status.proto"
             ]

      # Product references Address (embedded, placed in the accounts file) and User.
      assert catalog.imports == [
               "ashgrpc/test/accounts/v1/accounts.proto",
               "google/type/date.proto"
             ]
    end

    test "every message and service has a module and a source", %{schema: schema} do
      for file <- schema.files, message <- file.messages do
        assert message.module, "#{message.full_name} has no module"
        assert message.source, "#{message.full_name} has no source"

        for field <- message.fields,
            do: assert(field.source, "#{message.full_name}.#{field.name}")
      end

      for file <- schema.files, service <- file.services do
        assert service.module
        assert service.source == file.source
        for rpc <- service.rpcs, do: assert({:action, _, _, %AshGrpc.Resource.Rpc{}} = rpc.source)
      end
    end

    test "every field gets a number", %{schema: schema} do
      for file <- schema.files, message <- file.messages, field <- message.fields do
        assert is_integer(field.number), "#{message.full_name}.#{field.name}"
      end
    end
  end

  describe "record messages" do
    test "resource message", %{schema: schema} do
      user = message(schema, "#{@accounts}.User")

      assert %IR.Message{
               name: "User",
               module: AshGrpc.Test.Proto.Accounts.V1.User,
               doc: "A user (proto)",
               source: {:resource, User},
               reserved_numbers: [5, {10, 12}, {100, :max}],
               reserved_names: ["legacy_name"],
               options: [%IR.Option{name: "(my.ext).table", value: "users"}]
             } = user

      assert field_names(user) == ~w(id email name age role score active tags profile addresses
               settings payload secret inserted_at display_name is_adult posts_count posts)

      assert %IR.Field{number: 1, type: :string, label: nil, source: {:attribute, User, :id}} =
               field(user, "id")

      assert %IR.Field{number: 2, label: nil, doc: "Primary email", json_name: "emailAddress"} =
               field(user, "email")

      assert %IR.Field{type: :string, label: :optional, deprecated?: true, doc: nil} =
               field(user, "name")

      assert [%IR.Option{name: "(my.ext).sensitive", value: true}] = field(user, "name").options
      assert %IR.Field{type: :int64, label: :optional} = field(user, "age")
      assert %IR.Field{type: :bool, label: nil} = field(user, "active")
      assert %IR.Field{type: :string, label: :repeated} = field(user, "tags")
      assert %IR.Field{type: {:message, "google.protobuf.Struct"}} = field(user, "settings")
      assert %IR.Field{type: {:message, "google.protobuf.Value"}} = field(user, "payload")

      assert %IR.Field{number: 20, type: {:message, "google.protobuf.Timestamp"}, label: nil} =
               field(user, "inserted_at")

      assert %IR.Field{type: :string, source: {:calculation, User, :display_name}} =
               field(user, "display_name")

      assert %IR.Field{type: :bool, source: {:calculation, User, :adult?}} =
               field(user, "is_adult")

      assert %IR.Field{type: :int64, label: nil, source: {:aggregate, User, :posts_count}} =
               field(user, "posts_count")

      assert %IR.Field{
               type: {:message, "#{@accounts}.Post"},
               label: :repeated,
               source: {:relationship, User, :posts}
             } = field(user, "posts")
    end

    test "embedded resources become messages", %{schema: schema} do
      assert %IR.Message{
               name: "UserProfile",
               source: {:embedded, Profile},
               module: AshGrpc.Test.Proto.Accounts.V1.UserProfile
             } = profile = message(schema, "#{@accounts}.UserProfile")

      assert field_names(profile) == ["bio", "home", "note"]
      assert %IR.Field{number: 1} = field(profile, "bio")

      assert %IR.Field{number: 7, source: {:attribute, Profile, :private_note}} =
               field(profile, "note")

      assert %IR.Field{type: {:message, "#{@accounts}.Address"}, label: nil} =
               field(profile, "home")

      address = message(schema, "#{@accounts}.Address")
      assert %IR.Message{source: {:embedded, Address}} = address
      assert field_names(address) == ["street", "city"]
      assert %IR.Field{label: nil} = field(address, "city")

      user = message(schema, "#{@accounts}.User")

      assert %IR.Field{type: {:message, "#{@accounts}.UserProfile"}, label: nil} =
               field(user, "profile")

      assert %IR.Field{type: {:message, "#{@accounts}.Address"}, label: :repeated} =
               field(user, "addresses")
    end

    test "embedded resources are defined once, in the first referencing file", %{schema: schema} do
      definitions =
        for file <- schema.files,
            message <- file.messages,
            message.source == {:embedded, Address},
            do: file.path

      assert definitions == ["ashgrpc/test/accounts/v1/accounts.proto"]

      product = message(schema, "#{@catalog}.Product")
      assert %IR.Field{type: {:message, "#{@accounts}.Address"}} = field(product, "warehouse")

      assert %IR.Field{type: {:message, "#{@accounts}.User"}, label: nil} =
               field(product, "owner")

      assert %IR.Message{module: Ashgrpc.Test.Catalog.V1.Product, source: {:resource, Product}} =
               product
    end
  end

  describe "rpcs" do
    test "services", %{accounts: accounts, catalog: catalog} do
      assert [
               %IR.Service{
                 name: "AccountsService",
                 full_name: "#{@accounts}.AccountsService",
                 module: AshGrpc.Test.Proto.Accounts.V1.AccountsService.Service,
                 doc: "Users",
                 options: [%IR.Option{name: "deprecated", value: false}]
               },
               %IR.Service{
                 name: "AdminService",
                 doc: "Back office",
                 rpcs: [%IR.Rpc{name: "BanUser"}]
               },
               %IR.Service{
                 name: "PostsService",
                 rpcs: [%IR.Rpc{name: "ListPosts"}, %IR.Rpc{name: "CreatePost"}]
               },
               %IR.Service{name: "ExportService", rpcs: [%IR.Rpc{name: "ListEmails"}]}
             ] = accounts.services

      assert [
               %IR.Service{
                 name: "CatalogService",
                 module: Ashgrpc.Test.Catalog.V1.CatalogService.Service
               }
             ] =
               catalog.services
    end

    test "get", %{schema: schema, accounts: accounts} do
      assert %IR.Rpc{
               input: "#{@accounts}.GetUserRequest",
               output: "#{@accounts}.User",
               idempotency_level: :no_side_effects,
               client_streaming?: false,
               server_streaming?: false,
               source: {:action, User, :read, %{kind: :get, get_by: [:id], load: [:posts]}}
             } = rpc(accounts, "GetUser")

      request = message(schema, "#{@accounts}.GetUserRequest")
      assert %IR.Message{source: {:action_input, User, :read}} = request
      assert field_names(request) == ["id", "read_mask"]
      assert %IR.Field{label: nil, source: {:attribute, User, :id}} = field(request, "id")

      assert %IR.Field{type: {:message, "google.protobuf.FieldMask"}} =
               field(request, "read_mask")

      # get? action: arguments only
      assert ["email"] = field_names(message(schema, "#{@accounts}.GetUserByEmailRequest"))

      assert %IR.Field{label: nil} =
               field(message(schema, "#{@accounts}.GetUserByEmailRequest"), "email")

      # default get_by is the primary key
      assert ["id"] = field_names(message(schema, "#{@catalog}.GetProductRequest"))
    end

    test "list", %{schema: schema, accounts: accounts} do
      assert %IR.Rpc{output: "#{@accounts}.ListUsersResponse"} = rpc(accounts, "ListUsers")

      request = message(schema, "#{@accounts}.ListUsersRequest")
      # private arguments are not exposed
      assert field_names(request) == ~w(query page_size page_token filter order_by read_mask)

      assert %IR.Field{type: :int32, label: nil, source: {:special, :page_size}} =
               field(request, "page_size")

      response = message(schema, "#{@accounts}.ListUsersResponse")
      assert %IR.Message{source: {:action_output, User, :search}} = response

      assert [
               %IR.Field{name: "users", type: {:message, "#{@accounts}.User"}, label: :repeated},
               %IR.Field{name: "next_page_token", type: :string, label: nil},
               %IR.Field{name: "total_size", type: :int64, label: :optional}
             ] = response.fields

      assert ["posts", "next_page_token", "total_size"] =
               field_names(message(schema, "#{@accounts}.ListPostsResponse"))
    end

    test "server stream", %{accounts: accounts} do
      assert %IR.Rpc{
               input: "#{@accounts}.WatchUsersRequest",
               output: "#{@accounts}.User",
               server_streaming?: true,
               client_streaming?: false
             } = rpc(accounts, "WatchUsers")
    end

    test "create", %{schema: schema, accounts: accounts} do
      assert %IR.Rpc{output: "#{@accounts}.User", idempotency_level: nil} =
               rpc(accounts, "CreateUser")

      request = message(schema, "#{@accounts}.CreateUserRequest")

      assert field_names(request) ==
               ~w(email name age role score active tags profile addresses settings payload)

      # required (allow_nil? false, no default) → implicit presence; defaults → optional
      assert %IR.Field{label: nil} = field(request, "email")
      assert %IR.Field{label: :optional} = field(request, "active")
      # the record field's representation is reused
      assert %IR.Field{type: {:message, "google.protobuf.Value"}} = field(request, "payload")

      # renamed request with an argument
      assert %IR.Rpc{input: "#{@accounts}.SignUpRequest", doc: "Sign up"} =
               rpc(accounts, "Register")

      sign_up = message(schema, "#{@accounts}.SignUpRequest")
      assert field_names(sign_up) == ~w(email name age profile password)

      assert %IR.Field{label: nil, source: {:argument, User, :register, :password}} =
               field(sign_up, "password")

      # wrapped input
      assert [
               %IR.Field{
                 name: "user",
                 type: {:message, "#{@accounts}.User"},
                 source: {:special, :record}
               }
             ] =
               message(schema, "#{@accounts}.CreateUserWrappedRequest").fields

      # external response module
      assert %IR.Rpc{output: "external.v1.Post"} = rpc(accounts, "CreatePost")
    end

    test "client stream", %{schema: schema, accounts: accounts} do
      assert %IR.Rpc{
               input: "#{@accounts}.ImportUsersRequest",
               output: "#{@accounts}.ImportUsersResponse",
               client_streaming?: true,
               server_streaming?: false
             } = rpc(accounts, "ImportUsers")

      assert [
               %IR.Field{name: "count", type: :int64},
               %IR.Field{name: "errors", type: {:message, "google.rpc.Status"}, label: :repeated}
             ] = message(schema, "#{@accounts}.ImportUsersResponse").fields
    end

    test "update", %{schema: schema, accounts: accounts} do
      assert %IR.Rpc{output: "#{@accounts}.User", idempotency_level: :idempotent} =
               rpc(accounts, "UpdateUser")

      request = message(schema, "#{@accounts}.UpdateUserRequest")
      assert ["id" | _] = field_names(request)
      assert List.last(field_names(request)) == "update_mask"
      assert %IR.Field{label: nil} = field(request, "id")
      # update inputs are never required
      assert %IR.Field{label: :optional} = field(request, "email")

      assert [%IR.Field{name: "user"}] = message(schema, "#{@accounts}.RenameUserRequest").fields
    end

    test "destroy", %{schema: schema, accounts: accounts} do
      assert %IR.Rpc{output: "google.protobuf.Empty"} = rpc(accounts, "DeleteUser")
      assert ["id"] = field_names(message(schema, "#{@accounts}.DeleteUserRequest"))

      assert %IR.Rpc{output: "#{@accounts}.User", deprecated?: true} =
               rpc(accounts, "ArchiveUser")

      assert ["id", "reason"] = field_names(message(schema, "#{@accounts}.ArchiveUserRequest"))
    end

    test "generic actions", %{schema: schema, accounts: accounts} do
      assert %IR.Rpc{
               output: "#{@accounts}.PingResponse",
               idempotency_level: :no_side_effects,
               options: [%IR.Option{name: "(my.ext).public", value: true}]
             } = rpc(accounts, "Ping")

      assert [%IR.Field{name: "value", type: :string, source: {:special, :value}}] =
               message(schema, "#{@accounts}.PingResponse").fields

      # no return type → Empty
      assert %IR.Rpc{output: "google.protobuf.Empty"} = rpc(accounts, "BanUser")
      # message return types are returned directly
      assert %IR.Rpc{output: "#{@accounts}.UserProfile"} = rpc(accounts, "ExportProfile")
      # repeated returns are wrapped; renamed response
      assert %IR.Rpc{output: "#{@accounts}.EmailList"} = rpc(accounts, "ListEmails")

      assert [%IR.Field{name: "value", type: :string, label: :repeated}] =
               message(schema, "#{@accounts}.EmailList").fields
    end

    test "bidi stream", %{accounts: accounts} do
      assert %IR.Rpc{
               input: "#{@accounts}.SyncRequest",
               output: "#{@accounts}.User",
               client_streaming?: true,
               server_streaming?: true,
               source: {:action, User, :read, %{handler: AshGrpc.Test.SyncHandler}}
             } = rpc(accounts, "Sync")
    end
  end

  describe "numbers and the lock" do
    test "locked numbers are kept and the lock is returned" do
      lock = %Lock{
        messages: %{
          "#{@catalog}.Product" => %{
            fields: %{"title" => 9, "price" => 4},
            reserved_numbers: [],
            reserved_names: []
          }
        }
      }

      assert {:ok, schema, new_lock} = Schema.build_with_lock([Accounts, Catalog], lock: lock)
      product = message(schema, "#{@catalog}.Product")
      assert %IR.Field{number: 9} = field(product, "title")
      assert %IR.Field{number: 4} = field(product, "price")
      assert numbers = new_lock.messages["#{@catalog}.Product"].fields
      assert numbers["title"] == 9
      assert Map.has_key?(new_lock.messages, "#{@accounts}.ListUsersResponse")

      assert {:ok, ^schema} = Schema.build([Accounts, Catalog], lock: lock)
    end
  end

  describe "errors" do
    test "domains must use AshGrpc.Domain" do
      assert {:error, [%Spark.Error.DslError{} = error]} = Schema.build([String])

      assert Exception.message(error) =~
               "String is not an Ash domain using the AshGrpc.Domain extension"
    end

    test "relationships to resources outside the schema" do
      assert {:error, errors} = Schema.build([Catalog])

      assert Enum.any?(
               errors,
               &(Exception.message(&1) =~
                   "relationship :owner points to AshGrpc.Test.User, which is not part of the schema")
             )
    end

    test "builder-level errors" do
      assert {:error, errors} =
               Schema.build([AshGrpc.Test.Fixtures.SameA, AshGrpc.Test.Fixtures.SameB])

      messages = Enum.map(errors, &Exception.message/1)

      assert Enum.any?(
               messages,
               &(&1 =~
                   ~s(message ashgrpc.test.same.v1.ListThingsRequest has more than one field named "page_size"))
             )

      assert Enum.any?(
               messages,
               &(&1 =~
                   ~s(`response_message: "ThingReply"` cannot rename the response: this rpc returns ashgrpc.test.same.v1.Thing))
             )

      assert Enum.any?(messages, &(&1 =~ "ashgrpc.test.same.v1.Thing is defined more than once"))

      assert Enum.any?(
               messages,
               &(&1 =~ "ashgrpc.test.same.v1.SameService is defined more than once")
             )

      refute Enum.any?(messages, &(&1 =~ "EchoReply"))
    end
  end
end
