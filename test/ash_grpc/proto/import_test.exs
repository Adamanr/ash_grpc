defmodule AshGrpc.Proto.ImportTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.Import
  alias AshGrpc.Proto.IR
  alias AshGrpc.Proto.IR.Option

  @root "test/fixtures/protos"
  @includes [@root, Path.join(@root, "third_party")]
  @fixtures [
    "acme/billing/v1/billing.proto",
    "acme/legacy/v1/legacy.proto",
    "acme/editions/v1/editions.proto",
    "nopackage.proto"
  ]

  setup_all do
    {:ok, schema} = Import.from_files(files(@fixtures), include_paths: @includes)
    %{schema: schema}
  end

  defp files(paths), do: Enum.map(paths, &Path.join(@root, &1))

  defp file(schema, path), do: Enum.find(schema.files, &(&1.path == path))

  defp lookup!(schema, full_name) do
    {:ok, found} = IR.Schema.lookup(schema, full_name)
    found
  end

  defp field(message, name), do: Enum.find(message.fields, &(&1.name == name))

  defp descriptor_set(paths, includes \\ @includes) do
    {:ok, binary} =
      AshGrpc.Proto.Import.Protoc.descriptor_set(files(paths), include_paths: includes)

    binary
  end

  describe "files" do
    test "imports dependencies and drops well-known and googleapis files", %{schema: schema} do
      assert Enum.map(schema.files, & &1.path) == [
               "acme/common/v1/money.proto",
               "acme/options/v1/options.proto",
               "acme/billing/v1/billing.proto",
               "acme/legacy/v1/legacy.proto",
               "acme/editions/v1/editions.proto",
               "nopackage.proto"
             ]
    end

    test "file metadata", %{schema: schema} do
      file = file(schema, "acme/billing/v1/billing.proto")

      assert file.package == "acme.billing.v1"
      assert file.syntax == :proto3
      assert file.source == {:external, "acme/billing/v1/billing.proto"}
      assert file.doc == "The billing package."

      assert file.imports == [
               "acme/common/v1/money.proto",
               "acme/options/v1/options.proto",
               "google/protobuf/empty.proto",
               "google/protobuf/field_mask.proto",
               "google/protobuf/timestamp.proto",
               "google/type/date.proto"
             ]

      assert file.public_imports == ["acme/options/v1/options.proto"]
    end

    test "syntaxes", %{schema: schema} do
      assert file(schema, "acme/legacy/v1/legacy.proto").syntax == :proto2
      assert file(schema, "acme/editions/v1/editions.proto").syntax == {:edition, "2023"}
      assert file(schema, "nopackage.proto").package == nil
    end

    test "file options: standard (non-default) and custom", %{schema: schema} do
      assert file(schema, "acme/billing/v1/billing.proto").options == [
               %Option{name: "java_package", value: "com.acme.billing.v1"},
               %Option{name: "java_multiple_files", value: true},
               %Option{name: "go_package", value: "github.com/acme/gen/billing/v1;billingv1"},
               %Option{name: "(acme.options.v1.owner)", value: "billing-team"}
             ]

      assert file(schema, "acme/legacy/v1/legacy.proto").options == [
               %Option{name: "java_outer_classname", value: "LegacyProto"}
             ]
    end

    test "every entity carries its source", %{schema: schema} do
      file = file(schema, "acme/billing/v1/billing.proto")
      invoice = lookup!(schema, "acme.billing.v1.Invoice")
      service = hd(file.services)

      source = {:external, "acme/billing/v1/billing.proto"}
      assert invoice.source == source
      assert Enum.all?(invoice.fields, &(&1.source == source))
      assert lookup!(schema, "acme.billing.v1.Invoice.Status").source == source
      assert service.source == source
      assert Enum.all?(service.rpcs, &(&1.source == source))
    end
  end

  describe "messages" do
    test "names, modules and docs", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      assert invoice.name == "Invoice"
      assert invoice.module == Acme.Billing.V1.Invoice
      assert invoice.doc == "An invoice.\n\nSecond paragraph."

      assert lookup!(schema, "acme.billing.v1.Invoice.Item").module ==
               Acme.Billing.V1.Invoice.Item

      discount = lookup!(schema, "acme.billing.v1.Invoice.Item.Discount")
      assert discount.module == Acme.Billing.V1.Invoice.Item.Discount
      assert discount.name == "Discount"

      assert field(discount, "applies_to").type ==
               {:enum, "acme.billing.v1.Invoice.Item.Kind"}

      assert lookup!(schema, "acme.billing.v1.Invoice.Item.Kind").module ==
               Acme.Billing.V1.Invoice.Item.Kind
    end

    test "map entry messages are dropped", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      assert Enum.map(invoice.nested_messages, & &1.name) == ["Item", "BankTransfer"]
      assert :error = IR.Schema.lookup(schema, "acme.billing.v1.Invoice.LabelsEntry")
    end

    test "field types and labels", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      types =
        Map.new(invoice.fields, fn field ->
          {field.name, {field.number, field.type, field.label}}
        end)

      assert types["id"] == {1, :string, nil}
      assert types["total"] == {2, {:message, "acme.common.v1.Money"}, nil}
      assert types["status"] == {3, {:enum, "acme.billing.v1.Invoice.Status"}, nil}
      assert types["note"] == {5, :string, :optional}
      assert types["items"] == {6, {:message, "acme.billing.v1.Invoice.Item"}, :repeated}
      assert types["labels"] == {7, {:map, :string, :string}, nil}

      assert types["items_by_id"] ==
               {11, {:map, :int64, {:message, "acme.billing.v1.Invoice.Item"}}, nil}

      assert types["status_by_region"] ==
               {12, {:map, :string, {:enum, "acme.billing.v1.Invoice.Status"}}, nil}

      assert types["created_at"] == {13, {:message, "google.protobuf.Timestamp"}, nil}
      assert types["due_on"] == {14, {:message, "google.type.Date"}, nil}

      assert types["optional_status"] ==
               {18, {:enum, "acme.billing.v1.Invoice.Status"}, :optional}

      assert types["currency"] == {19, {:enum, "acme.common.v1.Currency"}, nil}
    end

    test "all scalar types", %{schema: schema} do
      scalars = lookup!(schema, "acme.billing.v1.Scalars")

      assert Enum.map(scalars.fields, & &1.type) == IR.scalars()
      assert Enum.all?(scalars.fields, &is_nil(&1.label))
    end

    test "real oneofs vs synthetic proto3 optional oneofs", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      assert [%IR.Oneof{name: "payment", doc: "How the invoice gets paid.", options: options}] =
               invoice.oneofs

      assert options == [%Option{name: "(acme.options.v1.exclusive)", value: true}]

      members = invoice.fields |> Enum.filter(&(&1.oneof == "payment")) |> Enum.map(& &1.name)
      assert members == ["card_token", "bank_transfer", "wallet_id"]
      assert Enum.all?(invoice.fields, &(&1.oneof in [nil, "payment"]))

      assert field(invoice, "card_token").label == nil
      assert field(invoice, "card_token").doc == "Card token."
      assert field(invoice, "note").oneof == nil
    end

    test "docs from leading and trailing comments", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      assert field(invoice, "id").doc == "Invoice id."
      assert field(invoice, "total").doc == "Trailing comment."
      assert field(invoice, "status").doc == nil
      assert lookup!(schema, "acme.common.v1.Money").doc == "An amount of money in a currency."
    end

    test "json_name only when not the default", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      assert field(invoice, "legacy_code").json_name == "legacyCodeV1"
      assert field(invoice, "customer_email").json_name == nil
    end

    test "deprecated and standard field options", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      legacy = field(invoice, "legacy_code")
      assert legacy.deprecated?
      assert legacy.options == []

      refute field(invoice, "id").deprecated?
      assert field(invoice, "packed_numbers").options == [%Option{name: "packed", value: false}]
    end

    test "custom field options of every kind", %{schema: schema} do
      email = field(lookup!(schema, "acme.billing.v1.Invoice"), "customer_email")

      assert email.options == [
               %Option{name: "(acme.options.v1.sensitive)", value: true},
               %Option{name: "(acme.options.v1.sensitivity)", value: :SENSITIVITY_HIGH},
               %Option{
                 name: "(acme.options.v1.rules)",
                 value: %{
                   "min_len" => 3,
                   "max_len" => 254,
                   "tags" => ["pii", "email"],
                   "nested" => %{"flag" => true}
                 }
               },
               %Option{name: "(acme.options.v1.labels)", value: "a"},
               %Option{name: "(acme.options.v1.labels)", value: "b"},
               %Option{name: "(acme.options.v1.weight)", value: -7},
               %Option{name: "(acme.options.v1.ratio)", value: 0.5},
               %Option{name: "(acme.options.v1.checksum)", value: 42},
               %Option{name: "(acme.options.v1.score)", value: 1.5},
               %Option{name: "(acme.options.v1.blob)", value: <<1, 2>>}
             ]
    end

    test "custom message options", %{schema: schema} do
      assert lookup!(schema, "acme.billing.v1.Invoice").options == [
               %Option{name: "(acme.options.v1.table)", value: "invoices"},
               %Option{name: "(acme.options.v1.audited)", value: true}
             ]
    end

    test "reserved ranges are inclusive with :max", %{schema: schema} do
      invoice = lookup!(schema, "acme.billing.v1.Invoice")

      assert invoice.reserved_numbers == [4, {8, 10}, {1000, :max}]
      assert invoice.reserved_names == ["legacy_total", "old_status"]

      assert lookup!(schema, "acme.legacy.v1.Record").reserved_numbers == [5, {7, 9}]
    end
  end

  describe "enums" do
    test "values, aliases, reserved, docs and options", %{schema: schema} do
      status = lookup!(schema, "acme.billing.v1.Invoice.Status")

      assert status.module == Acme.Billing.V1.Invoice.Status
      assert status.allow_alias?

      assert Enum.map(status.values, &{&1.name, &1.number}) == [
               {"STATUS_UNSPECIFIED", 0},
               {"STATUS_DRAFT", 1},
               {"STATUS_OPEN", 2},
               {"STATUS_ISSUED", 2},
               {"STATUS_PAID", 3}
             ]

      assert status.reserved_numbers == [9, {20, 30}, {100, :max}]
      assert status.reserved_names == ["VOIDED"]
      assert status.options == [%Option{name: "(acme.options.v1.enum_note)", value: "status"}]

      draft = Enum.find(status.values, &(&1.name == "STATUS_DRAFT"))
      assert draft.doc == "Draft invoice."
      assert draft.options == [%Option{name: "(acme.options.v1.display)", value: "Draft"}]

      paid = Enum.find(status.values, &(&1.name == "STATUS_PAID"))
      assert paid.deprecated?
      assert paid.options == []
    end

    test "top-level enums", %{schema: schema} do
      region = lookup!(schema, "acme.billing.v1.Region")
      assert region.module == Acme.Billing.V1.Region
      refute region.allow_alias?
      assert lookup!(schema, "acme.common.v1.Currency").module == Acme.Common.V1.Currency
    end
  end

  describe "services" do
    test "service metadata", %{schema: schema} do
      {:ok, service} = IR.Schema.lookup_service(schema, "acme.billing.v1.BillingService")

      assert service.name == "BillingService"
      assert service.module == Acme.Billing.V1.BillingService.Service
      assert service.doc == "Manages invoices."

      assert service.options == [
               %Option{name: "deprecated", value: true},
               %Option{name: "(acme.options.v1.default_host)", value: "billing.acme.test"}
             ]
    end

    test "rpcs: types, streaming kinds, idempotency, deprecation", %{schema: schema} do
      {:ok, service} = IR.Schema.lookup_service(schema, "acme.billing.v1.BillingService")

      rpcs =
        Map.new(service.rpcs, fn rpc ->
          {rpc.name,
           {rpc.input, rpc.output, rpc.client_streaming?, rpc.server_streaming?,
            rpc.idempotency_level, rpc.deprecated?}}
        end)

      assert rpcs["GetInvoice"] ==
               {"acme.billing.v1.GetInvoiceRequest", "acme.billing.v1.Invoice", false, false,
                :no_side_effects, false}

      assert rpcs["DeleteInvoice"] ==
               {"acme.billing.v1.GetInvoiceRequest", "google.protobuf.Empty", false, false,
                :idempotent, true}

      assert rpcs["ListInvoices"] ==
               {"acme.billing.v1.ListInvoicesRequest", "acme.billing.v1.ListInvoicesResponse",
                false, false, nil, false}

      assert {_, _, false, true, nil, false} = rpcs["WatchInvoices"]
      assert {_, _, true, false, nil, false} = rpcs["Upload"]
      assert {_, _, true, true, nil, false} = rpcs["Sync"]

      get = Enum.find(service.rpcs, &(&1.name == "GetInvoice"))
      assert get.doc == "Fetches one invoice."
      assert get.options == [%Option{name: "(acme.options.v1.timeout_ms)", value: 1500}]

      delete = Enum.find(service.rpcs, &(&1.name == "DeleteInvoice"))
      assert delete.options == []
    end
  end

  describe "proto2" do
    test "labels and defaults", %{schema: schema} do
      record = lookup!(schema, "acme.legacy.v1.Record")

      fields = Map.new(record.fields, &{&1.name, {&1.label, &1.default}})

      assert fields["id"] == {:required, nil}
      assert fields["count"] == {:optional, -5}
      assert fields["name"] == {:optional, ~s(unnamed "x")}
      assert fields["active"] == {:optional, true}
      assert fields["ratio"] == {:optional, 2.5}
      assert fields["inf_value"] == {:optional, :infinity}
      assert fields["neg_inf_value"] == {:optional, :negative_infinity}
      assert fields["nan_value"] == {:optional, :nan}
      assert fields["raw"] == {:optional, <<?a, 1, 255>>}
      assert fields["color"] == {:optional, :GREEN}
      assert fields["big"] == {:optional, 18_446_744_073_709_551_615}
      assert fields["plain"] == {:optional, nil}
      assert fields["tags"] == {:repeated, nil}
    end

    test "enums without a zero value", %{schema: schema} do
      color = lookup!(schema, "acme.legacy.v1.Color")
      assert Enum.map(color.values, & &1.number) == [1, 2, 3]
    end
  end

  describe "editions" do
    test "presence resolved from features", %{schema: schema} do
      settings = lookup!(schema, "acme.editions.v1.Settings")
      labels = Map.new(settings.fields, &{&1.name, &1.label})

      assert labels == %{
               "name" => nil,
               "explicit_count" => :optional,
               "implicit_count" => nil,
               "required_key" => :required,
               "parent" => nil,
               "values" => :repeated,
               "mode" => :optional
             }

      inner = lookup!(schema, "acme.editions.v1.Settings.Inner")
      assert field(inner, "inherited").label == nil
    end

    test "features become options", %{schema: schema} do
      file = file(schema, "acme/editions/v1/editions.proto")
      assert file.options == [%Option{name: "features.field_presence", value: :IMPLICIT}]

      settings = lookup!(schema, "acme.editions.v1.Settings")

      assert field(settings, "explicit_count").options == [
               %Option{name: "features.field_presence", value: :EXPLICIT}
             ]

      assert lookup!(schema, "acme.editions.v1.Mode").options == [
               %Option{name: "features.enum_type", value: :CLOSED}
             ]
    end
  end

  describe "naming" do
    test "files without a package", %{schema: schema} do
      thing = lookup!(schema, "top_level_thing")
      assert thing.module == TopLevelThing
      assert lookup!(schema, "top_level_thing.inner_thing").module == TopLevelThing.InnerThing

      {:ok, service} = IR.Schema.lookup_service(schema, "PingService")
      assert service.module == PingService.Service
      assert hd(service.rpcs).input == "top_level_thing"
    end

    test ":module_prefix replaces the package" do
      {:ok, schema} =
        Import.from_descriptor_set(descriptor_set(["acme/billing/v1/billing.proto"]),
          module_prefix: MyApp.Proto
        )

      assert lookup!(schema, "acme.billing.v1.Invoice.Item").module == MyApp.Proto.Invoice.Item
      assert lookup!(schema, "acme.common.v1.Money").module == MyApp.Proto.Money

      {:ok, service} = IR.Schema.lookup_service(schema, "acme.billing.v1.BillingService")
      assert service.module == MyApp.Proto.BillingService.Service

      {:ok, schema} =
        Import.from_descriptor_set(descriptor_set(["nopackage.proto"]),
          module_prefix: "my_app.pb"
        )

      assert lookup!(schema, "top_level_thing").module == MyApp.Pb.TopLevelThing
    end

    test ":package_prefix is prepended to the package" do
      {:ok, schema} =
        Import.from_descriptor_set(descriptor_set(["acme/common/v1/money.proto"]),
          package_prefix: "my_app.proto"
        )

      assert lookup!(schema, "acme.common.v1.Money").module == MyApp.Proto.Acme.Common.V1.Money
    end

    test "module conflicts are reported" do
      set = descriptor_set(["unsupported/clash_a.proto", "unsupported/clash_b.proto"])

      assert {:ok, _} = Import.from_descriptor_set(set)

      assert {:error, {:module_conflict, %{X.Thing => ["clash.a.Thing", "clash.b.Thing"]}}} =
               Import.from_descriptor_set(set, module_prefix: X)
    end
  end

  describe "from_descriptor_set/2" do
    test "accepts a decoded descriptor set" do
      set =
        ["acme/common/v1/money.proto"]
        |> descriptor_set()
        |> Google.Protobuf.FileDescriptorSet.decode()

      assert {:ok, %IR.Schema{files: [%IR.File{path: "acme/common/v1/money.proto"}]}} =
               Import.from_descriptor_set(set)
    end

    test "rejects garbage" do
      assert {:error, {:invalid_descriptor_set, _}} =
               Import.from_descriptor_set(<<255, 255, 255>>)
    end

    test ":exclude controls which files are dropped" do
      {:ok, schema} =
        Import.from_descriptor_set(descriptor_set(["acme/common/v1/money.proto"]), exclude: [])

      assert Enum.map(schema.files, & &1.path) == [
               "google/type/date.proto",
               "acme/common/v1/money.proto"
             ]

      assert lookup!(schema, "google.type.Date").module == Google.Type.Date

      {:ok, schema} =
        Import.from_descriptor_set(descriptor_set(["acme/billing/v1/billing.proto"]),
          exclude: Import.default_excludes() ++ ["acme/options/"]
        )

      refute file(schema, "acme/options/v1/options.proto")
      # custom options are still decoded from the excluded file's extensions
      assert file(schema, "acme/billing/v1/billing.proto").options |> List.last() ==
               %Option{name: "(acme.options.v1.owner)", value: "billing-team"}
    end

    test "unresolved types are reported" do
      set = %Google.Protobuf.FileDescriptorSet{
        file: [
          %Google.Protobuf.FileDescriptorProto{
            name: "broken.proto",
            package: "broken",
            syntax: "proto3",
            message_type: [
              %Google.Protobuf.DescriptorProto{
                name: "Broken",
                field: [
                  %Google.Protobuf.FieldDescriptorProto{
                    name: "other",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_MESSAGE,
                    type_name: ".missing.Type"
                  },
                  %Google.Protobuf.FieldDescriptorProto{
                    name: "unknown_google",
                    number: 2,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_MESSAGE,
                    type_name: ".google.type.NoSuchType"
                  }
                ]
              }
            ]
          }
        ]
      }

      assert {:error, {:unresolved_types, ["google.type.NoSuchType", "missing.Type"]}} =
               Import.from_descriptor_set(set)

      assert {:ok, _} = Import.from_descriptor_set(set, validate_types?: false)
    end

    test "invalid identifiers are rejected" do
      set = %Google.Protobuf.FileDescriptorSet{
        file: [
          %Google.Protobuf.FileDescriptorProto{
            name: "evil.proto",
            package: "evil",
            syntax: "proto3",
            message_type: [%Google.Protobuf.DescriptorProto{name: "Bad\nName"}]
          }
        ]
      }

      assert {:error, {:unsupported, message}} = Import.from_descriptor_set(set)
      assert message =~ "invalid protobuf identifier"
    end

    test "proto2 groups are rejected" do
      assert {:error, {:unsupported, message}} =
               Import.from_files(files(["unsupported/groups.proto"]), include_paths: [@root])

      assert message =~ "unsupported.WithGroup.legacy: proto2 groups are not supported"
    end

    test "DELIMITED message encoding is rejected" do
      assert {:error, {:unsupported, message}} =
               Import.from_files(files(["unsupported/delimited.proto"]), include_paths: [@root])

      assert message =~ "DELIMITED"
    end
  end

  describe "from_files/2" do
    test "missing protoc" do
      assert {:error, {:protoc_not_found, "/nonexistent/protoc"}} =
               Import.from_files(files(["nopackage.proto"]),
                 include_paths: [@root],
                 protoc: "/nonexistent/protoc"
               )
    end

    test "explicit protoc path" do
      assert {:ok, _} =
               Import.from_files(files(["nopackage.proto"]),
                 include_paths: [@root],
                 protoc: System.find_executable("protoc")
               )
    end

    test "protoc errors are returned" do
      assert {:error, {:protoc_failed, status, output}} =
               Import.from_files(files(["acme/billing/v1/billing.proto"]), include_paths: [@root])

      assert status != 0
      assert output =~ "google/type/date.proto"
    end
  end

  describe "module_for/2" do
    test "resolves imported, well-known and googleapis types", %{schema: schema} do
      assert Import.module_for(schema, "acme.billing.v1.Invoice.Item") ==
               Acme.Billing.V1.Invoice.Item

      assert Import.module_for(schema, "google.protobuf.Timestamp") == Google.Protobuf.Timestamp
      assert Import.module_for(schema, "google.type.Date") == Google.Type.Date

      assert Import.module_for(nil, "google.rpc.BadRequest.FieldViolation") ==
               Google.Rpc.BadRequest.FieldViolation
    end
  end
end
