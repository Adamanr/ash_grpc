defmodule AshGrpc.DataLayerDslTest do
  use ExUnit.Case, async: true

  import AshGrpc.Test.DslHelpers

  alias AshGrpc.DataLayer.{Foreign, Info, Mapping}
  alias AshGrpc.Proto.IR
  alias AshGrpc.Test.Remote.{Proto, Ticket}

  describe "Foreign" do
    test "builds the IR of a compiled message and the types it references" do
      assert {:ok, %IR.Message{} = message, schema} = Foreign.message(Proto.ListTicketsResponse)
      assert message.module == Proto.ListTicketsResponse
      assert [%{name: "tickets", label: :repeated}, %{name: "next_page_token"}] = message.fields
      assert Enum.all?(message.fields, &is_nil(&1.source))

      assert {:ok, %IR.Message{module: Proto.Ticket}} =
               IR.Schema.lookup(schema, "ash_grpc.test.remote.v1.Ticket")

      assert {:ok, %IR.Enum{module: Proto.TicketStatus}} =
               IR.Schema.lookup(schema, "ash_grpc.test.remote.v1.TicketStatus")

      # well-known types are not part of the schema
      assert :error = IR.Schema.lookup(schema, "google.protobuf.Timestamp")
    end

    test "is cached and round-trips through the codec" do
      assert {:ok, schema} = Foreign.schema(Proto.Ticket)
      assert {:ok, ^schema} = Foreign.schema(Proto.Ticket)

      {message, schema} = Foreign.message!(Proto.Ticket)
      struct = %Proto.Ticket{id: "1", status: :TICKET_STATUS_OPEN, labels: ["a"]}

      assert {:ok, %{id: "1", status: :TICKET_STATUS_OPEN}} =
               AshGrpc.Codec.decode_message(struct, message, schema)
    end

    test "errors for modules that are not protobuf messages" do
      assert {:error, {:not_protobuf, String}} = Foreign.message(String)
      assert {:error, {:not_loaded, Nope.Nope}} = Foreign.schema(Nope.Nope)
      assert_raise ArgumentError, fn -> Foreign.message!(String) end
    end
  end

  describe "Mapping" do
    test "binds enums to Ash atoms" do
      specs = [{"status", :status, :atom, [one_of: [:open, :closed]]}]

      assert {:ok, %Proto.Ticket{status: :TICKET_STATUS_CLOSED}} =
               Mapping.encode(Proto.Ticket, %{status: :closed}, specs)

      assert {:ok, %{status: :open}} =
               Mapping.decode(%Proto.Ticket{status: :TICKET_STATUS_OPEN}, specs)

      assert {:ok, %{status: nil}} = Mapping.decode(%Proto.Ticket{}, specs)
    end

    test "field paths" do
      response = %Proto.EscalateResponse{ticket: %Proto.Ticket{id: "x"}}
      assert Mapping.get_path(response, [:ticket, "id"]) == "x"
      assert Mapping.get_path(%Proto.EscalateResponse{}, [:ticket, :id]) == nil
    end
  end

  describe "Info" do
    test "introspection" do
      assert Info.grpc_remote_client!(Ticket) == AshGrpc.Test.Remote.Client
      assert Info.field_name(Ticket, :owner) == "owner_id"
      assert Info.field_name(Ticket, :title) == "title"
      assert %{kind: :read, rpc: :list_tickets} = Info.read_operation(Ticket, :read)
      assert %{kind: :update, update_mask: :update_mask} = Info.operation(Ticket, :update)
      assert length(Info.operations(Ticket)) == 5
    end
  end

  describe "verifiers" do
    test "the client module must exist" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Remote.Fixtures.NoClient do
            use Ash.Resource,
              domain: nil,
              data_layer: AshGrpc.DataLayer,
              validate_domain_inclusion?: false

            grpc_remote do
              client(AshGrpc.Test.Remote.NoSuchClient)
              message AshGrpc.Test.Remote.Proto.Ticket
              read :list_tickets
            end

            attributes do
              attribute :id, :string, primary_key?: true, allow_nil?: false
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "is not a compiled `use AshGrpc.Client` module"))
    end

    test "rpcs must exist on the client's services" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Remote.Fixtures.UnknownRpc do
            use Ash.Resource,
              domain: nil,
              data_layer: AshGrpc.DataLayer,
              validate_domain_inclusion?: false

            grpc_remote do
              client(AshGrpc.Test.Remote.Client)
              message AshGrpc.Test.Remote.Proto.Ticket
              read :list_everything
            end

            attributes do
              attribute :id, :string, primary_key?: true, allow_nil?: false
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ "unknown rpc :list_everything"))
    end

    test "mapped fields must exist on the messages" do
      messages =
        dsl_error_messages do
          defmodule Elixir.AshGrpc.Test.Remote.Fixtures.UnknownFields do
            use Ash.Resource,
              domain: nil,
              data_layer: AshGrpc.DataLayer,
              validate_domain_inclusion?: false

            grpc_remote do
              client(AshGrpc.Test.Remote.Client)
              message AshGrpc.Test.Remote.Proto.Ticket
              fields owner: "owner"
            end

            attributes do
              attribute :id, :string, primary_key?: true, allow_nil?: false
            end
          end
        end

      assert Enum.any?(messages, &(&1 =~ ~s(has no field "owner")))

      for {entity, fragment} <- [
            {quote(do: read(:list_tickets, filter: [:title])),
             ~s(ListTicketsRequest has no field "title")},
            {quote(do: get(:get_ticket, by: :title)), ~s(GetTicketRequest has no field "title")},
            {quote(do: create(:create_ticket, request: :item)),
             ~s(CreateTicketRequest has no field "item")},
            {quote(do: update(:update_ticket, update_mask: :mask)),
             ~s(UpdateTicketRequest has no field "mask")},
            {quote(do: create(:escalate, response: [:nope])), "has no message field :nope"},
            {quote(do: read(:who_am_i, paginate: :none)), "has no repeated"}
          ] do
        module =
          Module.concat(AshGrpc.Test.Remote.Fixtures, "Bad#{System.unique_integer([:positive])}")

        messages =
          dsl_error_messages do
            Code.eval_quoted(
              quote do
                defmodule unquote(module) do
                  use Ash.Resource,
                    domain: nil,
                    data_layer: AshGrpc.DataLayer,
                    validate_domain_inclusion?: false

                  grpc_remote do
                    client(AshGrpc.Test.Remote.Client)
                    message AshGrpc.Test.Remote.Proto.Ticket
                    unquote(entity)
                  end

                  attributes do
                    attribute :id, :string, primary_key?: true, allow_nil?: false
                    attribute :title, :string
                  end
                end
              end
            )
          end

        assert Enum.any?(messages, &(&1 =~ fragment)), "#{fragment} not in #{inspect(messages)}"
      end
    end
  end
end
