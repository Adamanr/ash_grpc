defmodule AshGrpc.Test.Types.Schema do
  @moduledoc false
  # A miniature schema builder (what the WP-C builder does for a resource),
  # producing the IR that matches the hand-written modules in `proto.ex`.

  alias AshGrpc.Proto.IR
  alias AshGrpc.Test.Types
  alias AshGrpc.Type.Mapping

  @package "test.types.v1"
  @prefix AshGrpc.Test.Types.Proto

  @content_types [
    text: [type: :string],
    number: [type: :integer],
    day: [type: :date],
    ints: [type: {:array, :integer}]
  ]

  # {name, ash type, constraints, mapping opts}
  @fields [
    {:id, :uuid, [], allow_nil?: false},
    {:name, :string, [], []},
    {:count, :integer, [], []},
    {:ratio, :float, [], []},
    {:price, :decimal, [], []},
    {:active, :boolean, [], allow_nil?: false},
    {:born_on, :date, [], []},
    {:wakes_at, :time_usec, [], []},
    {:inserted_at, :utc_datetime_usec, [], []},
    {:local_at, :naive_datetime, [], []},
    {:ttl, :duration, [], []},
    {:role, Types.Role, [], []},
    {:status, Types.Status, [], []},
    {:kind, :atom, [one_of: [:small, :large]], name_hint: "RecordKind"},
    {:meta, :map, [], []},
    {:payload, :term, [], representation: {:message, "google.protobuf.Value"}},
    {:address, Types.Address, [], name_hint: "Address"},
    {:content, :union, [types: @content_types], name_hint: "Content"},
    {:labels, {:array, :string}, [nil_items?: true], name_hint: "Labels"},
    {:matrix, {:array, {:array, :integer}}, [], name_hint: "Matrix"},
    {:scores, {:array, :integer}, [], name_hint: "Scores", distinguish_nil?: true},
    {:tags, {:array, :string}, [], []},
    {:profile, Types.Profile, [], []},
    {:profiles, {:array, Types.Profile}, [], []},
    {:money, Types.Money, [], []},
    {:slug, Types.Slug, [], []},
    {:raw_id, :uuid, [], representation: :bytes},
    {:exact, :decimal, [], representation: {:message, "google.type.Decimal"}},
    {:big, :integer, [], representation: :string},
    {:small, :integer, [], representation: :int32},
    {:module, :module, [], []}
  ]

  def fields, do: @fields
  def package, do: @package

  def mapping_opts(extra \\ []) do
    Keyword.merge(
      [
        package: @package,
        module_prefix: @prefix,
        resolve_resource: fn Types.Profile -> @package <> ".Profile" end
      ],
      extra
    )
  end

  @doc "The IR schema plus the record message."
  def build do
    {fields, results} =
      @fields
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, type, constraints, opts}, number} ->
        {:ok, result} = Mapping.to_proto(type, constraints, mapping_opts(opts))

        field = %IR.Field{
          name: Atom.to_string(name),
          number: number,
          type: result.type,
          label: result.label,
          source: {:attribute, name, type, constraints}
        }

        {field, result}
      end)
      |> Enum.unzip()

    record = %IR.Message{
      name: "Record",
      full_name: @package <> ".Record",
      module: @prefix.Record,
      source: {:type, :record, []},
      fields: fields
    }

    messages = results |> Enum.flat_map(& &1.messages) |> Enum.uniq_by(& &1.full_name)
    enums = results |> Enum.flat_map(& &1.enums) |> Enum.uniq_by(& &1.full_name)

    file = %IR.File{
      path: "test/types/v1/types.proto",
      package: @package,
      imports: results |> Enum.flat_map(& &1.imports) |> Enum.uniq() |> Enum.sort(),
      messages: [record, profile_message() | messages],
      enums: enums
    }

    {%IR.Schema{files: [file]}, record}
  end

  # owned by the schema builder (WP-C) in the real pipeline
  defp profile_message do
    %IR.Message{
      name: "Profile",
      full_name: @package <> ".Profile",
      module: @prefix.Profile,
      source: {:embedded, Types.Profile},
      fields: [
        %IR.Field{
          name: "bio",
          number: 1,
          type: :string,
          label: :optional,
          source: {:attribute, :bio}
        },
        %IR.Field{
          name: "role",
          number: 2,
          type: {:enum, @package <> ".Role"},
          label: :optional,
          source: {:attribute, :role}
        },
        %IR.Field{
          name: "birthday",
          number: 3,
          type: {:message, "google.type.Date"},
          source: :birthday
        }
      ]
    }
  end
end
