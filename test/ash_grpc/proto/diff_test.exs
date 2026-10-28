defmodule AshGrpc.Proto.DiffTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.{Diff, IR, Lock}
  alias AshGrpc.Test.ProtoFixtures

  defp schema(file), do: ProtoFixtures.schema(file)
  defp shop, do: ProtoFixtures.shop_file()

  defp update_message(file, full_name, fun) do
    %{file | messages: Enum.map(file.messages, &update_in_message(&1, full_name, fun))}
  end

  defp update_in_message(%IR.Message{full_name: full_name} = message, full_name, fun),
    do: fun.(message)

  defp update_in_message(message, full_name, fun),
    do: %{
      message
      | nested_messages: Enum.map(message.nested_messages, &update_in_message(&1, full_name, fun))
    }

  defp update_field(file, message, field_name, fun) do
    update_message(file, message, fn m ->
      %{m | fields: Enum.map(m.fields, &if(&1.name == field_name, do: fun.(&1), else: &1))}
    end)
  end

  defp drop_field(file, message, field_name) do
    update_message(file, message, fn m ->
      %{m | fields: Enum.reject(m.fields, &(&1.name == field_name))}
    end)
  end

  defp update_enum(file, fun), do: %{file | enums: Enum.map(file.enums, fun)}

  defp update_rpc(file, rpc_name, fun) do
    %{
      file
      | services:
          Enum.map(file.services, fn s ->
            %{s | rpcs: Enum.map(s.rpcs, &if(&1.name == rpc_name, do: fun.(&1), else: &1))}
          end)
    }
  end

  defp changes(old, new), do: Diff.diff(schema(old), schema(new))
  defp kinds(changes), do: Enum.map(changes, &{&1.kind, &1.severity, &1.path})

  @user "acme.shop.v1.User"

  test "identical schemas have no changes" do
    assert changes(shop(), shop()) == []
    assert Diff.format([]) == "No changes."
  end

  describe "fields" do
    test "removal without reservation is breaking" do
      [change] = changes(shop(), drop_field(shop(), @user, "email"))
      assert change.kind == :field_removed
      assert change.severity == :breaking
      assert change.path == "acme.shop.v1.User.email"
      assert change.message =~ "without reserving its number and name"
    end

    test "removal with reserved number and name is safe" do
      new =
        shop()
        |> drop_field(@user, "email")
        |> update_message(
          @user,
          &%{
            &1
            | reserved_numbers: [2 | &1.reserved_numbers],
              reserved_names: ["email" | &1.reserved_names]
          }
        )

      assert [%{kind: :field_removed_reserved, severity: :safe}] = changes(shop(), new)
    end

    test "removal reserved through the lock is safe" do
      file = drop_field(shop(), @user, "email")
      {_, lock} = Lock.assign(shop(), %Lock{})
      {new, _lock} = Lock.assign(update_field(file, @user, "id", & &1), lock)

      assert [%{kind: :field_removed_reserved}] = changes(shop(), new)
    end

    test "number changed" do
      new = update_field(shop(), @user, "email", &%{&1 | number: 99})

      assert [{:field_number_changed, :breaking, "acme.shop.v1.User.email"}] =
               kinds(changes(shop(), new))
    end

    test "number reused by a renamed field" do
      new = update_field(shop(), @user, "email", &%{&1 | name: "mail"})
      assert [{:field_renamed, :breaking, "acme.shop.v1.User.mail"}] = kinds(changes(shop(), new))
    end

    test "json_name changed" do
      new = update_field(shop(), @user, "legacy_id", &%{&1 | json_name: nil})
      assert [%{kind: :field_json_name_changed, message: message}] = changes(shop(), new)
      assert message =~ ~s("legacyID" to "legacyId")
    end

    test "incompatible type changes" do
      for {field, type} <- [
            {"id", :bytes},
            {"role", {:enum, "acme.shop.v1.User.Status"}},
            {"created_at", {:message, "google.protobuf.Duration"}},
            {"attributes", {:map, :string, :int32}},
            {"score", :float},
            {"legacy_id", :sint64}
          ] do
        new = update_field(shop(), @user, field, &%{&1 | type: type})
        assert [%{kind: :field_type_changed, severity: :breaking}] = changes(shop(), new), field
      end
    end

    test "compatible type changes are safe" do
      new =
        shop()
        |> update_field(@user, "legacy_id", &%{&1 | type: :uint64})
        |> update_field(@user, "scores", &%{&1 | type: :sint64})

      assert [
               {:field_type_changed_compatible, :safe, "acme.shop.v1.User.legacy_id"},
               {:field_type_changed_compatible, :safe, "acme.shop.v1.User.scores"}
             ] = kinds(changes(shop(), new))
    end

    test "label changes" do
      repeated = update_field(shop(), @user, "id", &%{&1 | label: :repeated})
      assert [%{kind: :field_label_changed, severity: :breaking}] = changes(shop(), repeated)

      optional = update_field(shop(), @user, "id", &%{&1 | label: :optional})
      assert [%{kind: :field_presence_changed, severity: :safe}] = changes(shop(), optional)
    end

    test "oneof membership changes" do
      new = update_field(shop(), @user, "id", &%{&1 | oneof: "contact"})
      assert [%{kind: :field_oneof_changed, severity: :breaking}] = changes(shop(), new)
    end

    test "added fields are safe, reusing reserved numbers or names is not" do
      add = fn file, field ->
        update_message(file, @user, &%{&1 | fields: &1.fields ++ [field]})
      end

      assert [%{kind: :field_added, severity: :safe}] =
               changes(shop(), add.(shop(), %IR.Field{name: "nick", number: 30, type: :string}))

      assert [%{kind: :reserved_number_reused, severity: :breaking}] =
               changes(shop(), add.(shop(), %IR.Field{name: "nick", number: 16, type: :string}))

      assert [%{kind: :reserved_number_reused}] =
               changes(shop(), add.(shop(), %IR.Field{name: "nick", number: 5000, type: :string}))

      assert [%{kind: :reserved_name_reused}] =
               changes(shop(), add.(shop(), %IR.Field{name: "legacy", number: 30, type: :string}))
    end

    test "nested messages are compared too" do
      new = drop_field(shop(), "acme.shop.v1.User.Address", "street")

      assert [{:field_removed, :breaking, "acme.shop.v1.User.Address.street"}] =
               kinds(changes(shop(), new))
    end
  end

  describe "messages, enums, services, files" do
    test "messages and enums added/removed are safe" do
      new = %{
        shop()
        | messages: tl(shop().messages) ++ [%IR.Message{name: "X", full_name: "acme.shop.v1.X"}]
      }

      assert [
               {:message_removed, :safe, "acme.shop.v1.User"},
               {:message_removed, :safe, "acme.shop.v1.User.Address"},
               {:enum_removed, :safe, "acme.shop.v1.User.Status"},
               {:message_added, :safe, "acme.shop.v1.X"}
             ] =
               new
               |> then(&changes(shop(), &1))
               |> kinds()
               |> Enum.reject(&match?({_, _, "acme.shop.v1.UserService" <> _}, &1))
    end

    test "enum values" do
      role = fn file, fun ->
        update_enum(file, fn enum -> %{enum | values: fun.(enum.values)} end)
      end

      removed = role.(shop(), &Enum.reject(&1, fn v -> v.name == "ROLE_USER" end))

      assert [{:enum_value_removed, :breaking, "acme.shop.v1.Role.ROLE_USER"}] =
               kinds(changes(shop(), removed))

      reserved =
        removed
        |> update_enum(
          &%{&1 | reserved_numbers: [2 | &1.reserved_numbers], reserved_names: ["ROLE_USER"]}
        )

      assert [%{kind: :enum_value_removed_reserved, severity: :safe}] = changes(shop(), reserved)

      renumbered =
        role.(
          shop(),
          &Enum.map(&1, fn v -> if v.name == "ROLE_USER", do: %{v | number: 3}, else: v end)
        )

      assert [%{kind: :enum_value_number_changed, severity: :breaking}] =
               changes(shop(), renumbered)

      renamed =
        role.(
          shop(),
          &Enum.map(&1, fn v ->
            if v.name == "ROLE_USER", do: %{v | name: "ROLE_MEMBER"}, else: v
          end)
        )

      assert [
               {:enum_value_added, :safe, "acme.shop.v1.Role.ROLE_MEMBER"},
               {:enum_value_renamed, :breaking, "acme.shop.v1.Role.ROLE_USER"}
             ] = kinds(changes(shop(), renamed))

      reused = role.(shop(), &(&1 ++ [%IR.EnumValue{name: "ROLE_GUEST", number: 8}]))
      assert [%{kind: :reserved_number_reused}] = changes(shop(), reused)

      added = role.(shop(), &(&1 ++ [%IR.EnumValue{name: "ROLE_GUEST", number: 20}]))
      assert [%{kind: :enum_value_added, severity: :safe}] = changes(shop(), added)
    end

    test "rpc changes" do
      svc = "acme.shop.v1.UserService."

      assert [{:rpc_request_changed, :breaking, path}] =
               kinds(
                 changes(
                   shop(),
                   update_rpc(shop(), "GetUser", &%{&1 | input: "acme.shop.v1.User"})
                 )
               )

      assert path == svc <> "GetUser"

      assert [%{kind: :rpc_response_changed}] =
               changes(
                 shop(),
                 update_rpc(shop(), "GetUser", &%{&1 | output: "google.protobuf.Empty"})
               )

      assert [%{kind: :rpc_streaming_changed, message: message}] =
               changes(shop(), update_rpc(shop(), "ListUsers", &%{&1 | server_streaming?: false}))

      assert message == "streaming changed from server streaming to unary"

      assert [%{kind: :rpc_idempotency_changed, severity: :safe}] =
               changes(shop(), update_rpc(shop(), "GetUser", &%{&1 | idempotency_level: nil}))

      assert [
               {:rpc_added, :safe, "acme.shop.v1.UserService.FetchUser"},
               {:rpc_removed, :breaking, "acme.shop.v1.UserService.GetUser"}
             ] = kinds(changes(shop(), update_rpc(shop(), "GetUser", &%{&1 | name: "FetchUser"})))
    end

    test "service removal and package change" do
      assert [{:service_removed, :breaking, "acme.shop.v1.UserService"}] =
               kinds(changes(shop(), %{shop() | services: []}))

      [%{kind: :package_changed} = change] =
        changes(shop(), %{shop() | package: "acme.shop.v2"})
        |> Enum.filter(&(&1.kind == :package_changed))

      assert change.severity == :breaking
      assert change.path == "acme/shop/v1/shop.proto"
    end
  end

  test "breaking?/1, breaking/1 and format/1" do
    new =
      shop()
      |> drop_field(@user, "email")
      |> update_message(
        @user,
        &%{&1 | fields: &1.fields ++ [%IR.Field{name: "nick", number: 30, type: :string}]}
      )

    changes = changes(shop(), new)
    assert Diff.breaking?(changes)
    assert [%{kind: :field_removed}] = Diff.breaking(changes)
    refute Diff.breaking?(Enum.reject(changes, &(&1.severity == :breaking)))

    assert Diff.format(changes) == """
           [breaking] acme.shop.v1.User.email: field "email" (2) was removed without reserving its number and name
           [safe]     acme.shop.v1.User.nick: field "nick" (30) was added\
           """
  end
end
