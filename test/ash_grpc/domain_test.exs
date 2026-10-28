defmodule AshGrpc.DomainTest do
  use ExUnit.Case, async: true

  import AshGrpc.Test.DslHelpers

  alias AshGrpc.Domain.Info
  alias AshGrpc.Resource.Info, as: ResourceInfo
  alias AshGrpc.Test.{Accounts, Catalog, Post, Product, User}

  describe "Info" do
    test "configured values" do
      assert Info.package(Accounts) == "ashgrpc.test.accounts.v1"
      assert Info.file(Accounts) == "ashgrpc/test/accounts/v1/accounts.proto"
      assert Info.module_prefix(Accounts) == AshGrpc.Test.Proto.Accounts.V1

      assert Info.options(Accounts) == [
               go_package: "example.com/gen/accounts/v1;accountsv1",
               java_multiple_files: true
             ]

      assert Info.resources(Accounts) == [User, Post]

      assert Enum.map(Info.services(Accounts), & &1.name) == [
               "AccountsService",
               "AdminService",
               "PostsService"
             ]
    end

    test "derived values" do
      assert Info.package(Catalog) == "ashgrpc.test.catalog.v1"
      assert Info.file(Catalog) == "ashgrpc/test/catalog/v1/catalog.proto"
      assert Info.module_prefix(Catalog) == Ashgrpc.Test.Catalog.V1
      assert Info.default_service_name(Catalog) == "CatalogService"
      assert Info.grpc?(Catalog)
      refute Info.grpc?(User)
    end

    test "versioned packages" do
      assert Info.versioned_package?("a.b.v1")
      assert Info.versioned_package?("a.v2beta1")
      refute Info.versioned_package?("a.b")
    end

    test "service assignment" do
      service = fn resource, rpc ->
        Info.service_name(Accounts, resource, ResourceInfo.rpc(resource, rpc))
      end

      # rpc `service:` option
      assert service.(User, :list_emails) == "ExportService"
      # listed in a service's `rpcs`
      assert service.(User, :ban_user) == "AdminService"
      # resource listed in a service's `resources`
      assert service.(Post, :list_posts) == "PostsService"
      # catch-all service
      assert service.(User, :get_user) == "AccountsService"
      # derived default
      assert Info.service_name(Catalog, Product, ResourceInfo.rpc(Product, :get_product)) ==
               "CatalogService"
    end
  end

  describe "package verifier" do
    test "invalid package and file" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.BadPackageDomain do
            use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

            grpc do
              package "MyApp.Accounts"
              file "/abs/accounts.txt"
            end

            resources do
              allow_unregistered? true
            end
          end
        end

      assert Enum.any?(
               messages,
               &(&1 =~ ~s(package "MyApp.Accounts" must be dot-separated lower_snake_case))
             )

      assert Enum.any?(
               messages,
               &(&1 =~ ~s(file "/abs/accounts.txt" must be a relative path ending in .proto))
             )
    end

    test "unversioned packages warn" do
      warnings =
        dsl_warning_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.UnversionedDomain do
            use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

            grpc do
              package "myapp.accounts"
            end

            resources do
              allow_unregistered? true
            end
          end
        end

      assert Enum.any?(warnings, &(&1 =~ ~s(package "myapp.accounts" is not versioned)))
    end
  end

  describe "service verifier" do
    test "invalid services" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.ServiceResource do
            use Ash.Resource,
              domain: AshGrpc.Test.Fixtures.ServiceDomain,
              extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end

            grpc do
              rpc :list_things, :read
            end
          end

          defmodule Elixir.AshGrpc.Test.Fixtures.ServiceDomain do
            use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

            grpc do
              package "fixtures.services.v1"
              service "lowercase"
              service "OtherService", rpcs: [:nope], resources: [AshGrpc.Test.User]
            end

            resources do
              resource AshGrpc.Test.Fixtures.ServiceResource
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ ~s(service name "lowercase" must be PascalCase)))
      assert Enum.any?(messages, &(&1 =~ "rpc :nope is not declared by any resource"))

      assert Enum.any?(
               messages,
               &(&1 =~
                   "AshGrpc.Test.User is not a resource of AshGrpc.Test.Fixtures.ServiceDomain")
             )
    end

    test "rpc names must be unique per service and message names per domain" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.Dup.A.Thing do
            use Ash.Resource,
              domain: AshGrpc.Test.Fixtures.DupDomain,
              extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end

            grpc do
              rpc :list_things, :read
            end
          end

          defmodule Elixir.AshGrpc.Test.Fixtures.Dup.B.Thing do
            use Ash.Resource,
              domain: AshGrpc.Test.Fixtures.DupDomain,
              extensions: [AshGrpc.Resource]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end

            grpc do
              rpc :list_things, :read
            end
          end

          defmodule Elixir.AshGrpc.Test.Fixtures.DupDomain do
            use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

            grpc do
              package "fixtures.dup.v1"
            end

            resources do
              resource AshGrpc.Test.Fixtures.Dup.A.Thing
              resource AshGrpc.Test.Fixtures.Dup.B.Thing
            end
          end
        end

      assert Enum.any?(
               messages,
               &(&1 =~ "rpc ListThings is declared more than once in service DupService")
             )

      assert Enum.any?(messages, &(&1 =~ ~s(message name "Thing" is used by)))
    end

    test "services without the Service suffix warn" do
      warnings =
        dsl_warning_messages do
          defmodule Elixir.AshGrpc.Test.Fixtures.SuffixDomain do
            use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

            grpc do
              package "fixtures.suffix.v1"
              service "Accounts"
            end

            resources do
              allow_unregistered? true
            end
          end
        end

      assert Enum.any?(warnings, &(&1 =~ ~s(service "Accounts" should end with "Service")))
    end
  end
end
