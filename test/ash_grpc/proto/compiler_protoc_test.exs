defmodule AshGrpc.Proto.CompilerProtocTest do
  @moduledoc """
  Cross-checks `AshGrpc.Proto.Compiler` against the real toolchain: the IR is
  rendered to `.proto`, compiled by `protoc` and turned into Elixir modules by
  the protoc-gen-elixir generator. Descriptors, message props and the wire
  format must match the modules AshGrpc compiles directly from the IR.
  """
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.Compiler
  alias AshGrpc.Test.{Protoc, ProtoFixtures}

  @moduletag :protoc
  @moduletag :tmp_dir
  unless Protoc.available?(), do: @moduletag(skip: "protoc is not installed")

  @ours AshGrpc.Test.Cross.Ours
  @ref_prefix "ash_grpc.test.cross.ref"
  @ref AshGrpc.Test.Cross.Ref

  setup_all do
    files = [
      ProtoFixtures.shop_file(Module.concat(@ours, Shop)),
      ProtoFixtures.legacy_file(Module.concat(@ours, Legacy))
    ]

    dir = Path.join(System.tmp_dir!(), "ash_grpc_cross_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    paths = Protoc.write_files!(files, dir)
    set = Protoc.descriptor_set!(dir, paths)

    for path <- paths do
      set |> Protoc.generate_elixir!(path, @ref_prefix) |> Code.compile_string()
    end

    Compiler.compile(ProtoFixtures.schema(files))
    %{files: files, set: set}
  end

  defp ours(name), do: Module.concat([@ours | List.wrap(name)])
  defp ref(name), do: Module.concat([@ref | List.wrap(name)])

  @pairs [
    {[Shop, User], [Acme, Shop, V1, User]},
    {[Shop, User, Address], [Acme, Shop, V1, User, Address]},
    {[Shop, User, AttributesEntry], [Acme, Shop, V1, User, AttributesEntry]},
    {[Shop, User, RoleByOrgEntry], [Acme, Shop, V1, User, RoleByOrgEntry]},
    {[Shop, User, AddressesEntry], [Acme, Shop, V1, User, AddressesEntry]},
    {[Shop, User, Status], [Acme, Shop, V1, User, Status]},
    {[Shop, Role], [Acme, Shop, V1, Role]},
    {[Shop, GetUserRequest], [Acme, Shop, V1, GetUserRequest]},
    {[Shop, ListUsersRequest], [Acme, Shop, V1, ListUsersRequest]},
    {[Shop, UserService, Service], [Acme, Shop, V1, UserService, Service]},
    {[Legacy, Item], [Acme, Legacy, Item]},
    {[Legacy, Kind], [Acme, Legacy, Kind]}
  ]

  test "descriptors are identical to protoc's" do
    for {our, theirs} <- @pairs do
      assert strip_custom(ours(our).descriptor()) == strip_custom(ref(theirs).descriptor()),
             "descriptor mismatch for #{inspect(ours(our))}"
    end
  end

  test "file descriptors are identical to protoc's", %{files: files, set: set} do
    for file <- files do
      protoc = Enum.find(set.file, &(&1.name == file.path))
      assert strip_custom(Compiler.file_descriptor(file)) == strip_custom(protoc)
    end
  end

  test "message props are equivalent" do
    for {our, theirs} <- @pairs, function_exported?(ours(our), :__message_props__, 0) do
      assert normalize_props(ours(our).__message_props__()) ==
               normalize_props(ref(theirs).__message_props__()),
             "props mismatch for #{inspect(ours(our))}"
    end
  end

  test "service rpc calls are equivalent" do
    ours = ours([Shop, UserService, Service])
    theirs = ref([Acme, Shop, V1, UserService, Service])
    assert ours.__meta__(:name) == theirs.__meta__(:name)

    shape = fn calls ->
      Enum.map(calls, fn {name, {_, req_stream}, {_, res_stream}, opts} ->
        {name, req_stream, res_stream, opts}
      end)
    end

    assert shape.(ours.__rpc_calls__()) == shape.(theirs.__rpc_calls__())
  end

  test "wire format is compatible in both directions" do
    user = ours([Shop, User])
    address = ours([Shop, User, Address])

    value =
      struct!(user,
        id: "u1",
        email: "",
        role: :ROLE_USER,
        tags: ["a"],
        attributes: %{"k" => "v"},
        role_by_org: %{-5 => :ROLE_ADMIN},
        created_at: %Google.Protobuf.Timestamp{seconds: 1},
        address: struct!(address, street: "s", status: :STATUS_ACTIVE),
        contact: {:phone, "123"},
        score: 2.5,
        legacy_id: -9,
        scores: [1, -1],
        addresses: %{"x" => struct!(address, zip_code: "z")},
        status: :STATUS_UNSPECIFIED,
        avatar: "bin",
        counter: 7
      )

    binary = user.encode(value)
    theirs = ref([Acme, Shop, V1, User]).decode(binary)
    assert theirs.contact == {:phone, "123"}
    assert theirs.email == ""
    assert theirs.status == :STATUS_UNSPECIFIED
    assert theirs.role_by_org == %{-5 => :ROLE_ADMIN}
    assert ref([Acme, Shop, V1, User]).encode(theirs) == binary
    assert user.decode(ref([Acme, Shop, V1, User]).encode(theirs)) == value

    item = ours([Legacy, Item])
    ref_item = ref([Acme, Legacy, Item])
    encoded = item.encode(struct!(item, id: 3, name: "n", flags: [1, 2]))
    assert %{id: 3, name: "n", flags: [1, 2]} = ref_item.decode(encoded)
  end

  # Custom options are not encoded by AshGrpc (see Compiler moduledoc): drop
  # extension data so the rest of the descriptor can be compared.
  defp strip_custom(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn
      {:__unknown_fields__, _} -> {:__unknown_fields__, []}
      {:__pb_extensions__, _} -> {:__pb_extensions__, %{}}
      {key, value} -> {key, strip_custom(value)}
    end)
    |> then(&struct(struct.__struct__, &1))
    |> drop_empty_options()
  end

  defp strip_custom(list) when is_list(list), do: Enum.map(list, &strip_custom/1)
  defp strip_custom(other), do: other

  defp drop_empty_options(%{options: %mod{} = options} = struct) do
    if options == struct(mod), do: %{struct | options: nil}, else: struct
  end

  defp drop_empty_options(struct), do: struct

  # Module names differ between the two sets; everything else must be equal.
  defp normalize_props(props) do
    field_props =
      Map.new(props.field_props, fn {num, field} ->
        {num, %{field | type: type_name(field.type)}}
      end)

    %{props | field_props: field_props}
  end

  defp type_name({:enum, mod}), do: {:enum, mod.full_name()}

  defp type_name(mod) when is_atom(mod) do
    if function_exported?(mod, :full_name, 0), do: mod.full_name(), else: mod
  end
end
