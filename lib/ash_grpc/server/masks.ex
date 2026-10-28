defmodule AshGrpc.Server.Masks do
  @moduledoc """
  Read masks (AIP-157), update masks (AIP-134) and the `filter`/`order_by` request fields
  (AIP-160/132) of the default handler.

    * `read_mask` paths are proto field names of the record message; attributes are selected
      (plus the primary key), calculations, aggregates and relationships are loaded only when
      listed. Without a mask the rpc's default load applies.
    * `update_mask` paths are proto field names of the (record) input; only those inputs are
      changed, absent ones are set to `nil`/`[]`.
    * `filter` is a JSON object in Ash's input filter syntax (`{"price": {"gt": 10}}`) applied
      with `Ash.Query.filter_input/2`, so field policies are honoured; keys may use proto field
      names. `order_by` is `"field [asc|desc], ..."`, applied with `Ash.Query.sort_input/2`.
  """

  alias AshGrpc.Proto.IR
  alias AshGrpc.Server.Context

  @doc "Applies the request's `read_mask` (or the default load) to a query."
  @spec apply_read_mask(Ash.Query.t(), struct(), Context.t()) :: Ash.Query.t()
  def apply_read_mask(query, request, %Context{} = ctx) do
    base = default_load(ctx)

    case mask_paths(request, :read_mask) do
      nil ->
        Ash.Query.load(query, base)

      paths ->
        fields = record_fields(ctx.record)

        selected =
          Enum.map(paths, fn path ->
            Map.get(fields, top(path)) || invalid!("read_mask", "unknown field #{inspect(path)}")
          end)

        attributes = for {:attribute, name} <- selected, do: name
        others = for {kind, name} <- selected, kind != :attribute, do: name

        load =
          Enum.filter(base, &(load_name(&1) in others)) ++
            Enum.reject(others, fn name -> Enum.any?(base, &(load_name(&1) == name)) end)

        query
        |> Ash.Query.select(Ash.Resource.Info.primary_key(ctx.resource) ++ attributes)
        |> Ash.Query.load(load)
    end
  end

  @doc """
  The default load of an rpc: calculations/aggregates of the message plus the rpc `load`.
  """
  @spec default_load(Context.t()) :: list()
  def default_load(%Context{} = ctx) do
    message_fields =
      case ctx.record do
        %IR.Message{} = record -> record_fields(record) |> Map.values() |> Enum.map(&elem(&1, 1))
        nil -> []
      end

    computed =
      ctx.resource
      |> AshGrpc.Resource.Info.default_load()
      |> Enum.filter(&(&1 in message_fields))

    Enum.uniq(computed ++ List.wrap(ctx.config.load))
  end

  @doc """
  Paths of the request's `update_mask` (validated against `message`), or `nil` when the
  request has no (or an empty) mask.
  """
  @spec update_paths(struct(), IR.Message.t() | nil) :: [String.t()] | nil
  def update_paths(request, message) do
    case mask_paths(request, :update_mask) do
      nil ->
        nil

      paths ->
        names = if message, do: MapSet.new(message.fields, & &1.name), else: MapSet.new()

        paths |> Enum.map(&known_path!(&1, names)) |> Enum.uniq()
    end
  end

  defp known_path!(path, names) do
    name = top(path)

    if MapSet.member?(names, name),
      do: name,
      else: invalid!("update_mask", "unknown field #{inspect(path)}")
  end

  @doc "Applies the `filter` and `order_by` request fields (rpcs with `filter?: true`)."
  @spec apply_filter(Ash.Query.t(), struct(), Context.t()) :: Ash.Query.t()
  def apply_filter(query, request, %Context{config: %{filter?: true}} = ctx) do
    names =
      ctx.record
      |> record_fields()
      |> Map.new(fn {proto, {_kind, name}} -> {proto, Atom.to_string(name)} end)

    query
    |> filter(Map.get(request, :filter), names)
    |> sort(Map.get(request, :order_by), names)
  end

  def apply_filter(query, _request, _ctx), do: query

  defp filter(query, blank, _names) when blank in [nil, ""], do: query

  defp filter(query, filter, names) do
    case Jason.decode(filter) do
      {:ok, map} when is_map(map) ->
        Ash.Query.filter_input(query, rename_keys(map, names))

      _ ->
        invalid!("filter", "must be a JSON object in Ash input filter syntax")
    end
  end

  defp rename_keys(map, names) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in ["and", "or"] and is_list(value) ->
        {key, Enum.map(value, &rename_keys(&1, names))}

      {"not", value} ->
        {"not", rename_keys(value, names)}

      {key, value} ->
        {Map.get(names, key, key), value}
    end)
  end

  defp rename_keys(other, _names), do: other

  defp sort(query, blank, _names) when blank in [nil, ""], do: query

  defp sort(query, order_by, names) do
    sort =
      order_by
      |> String.split(",", trim: true)
      |> Enum.map(fn item ->
        case String.split(item) do
          [field] ->
            Map.get(names, field, field)

          [field, direction] ->
            direction(Map.get(names, field, field), String.downcase(direction))

          _ ->
            invalid!("order_by", "invalid order #{inspect(item)}")
        end
      end)

    Ash.Query.sort_input(query, Enum.join(sort, ","))
  end

  defp direction(field, "asc"), do: field
  defp direction(field, "desc"), do: "-" <> field
  defp direction(_field, other), do: invalid!("order_by", "invalid direction #{inspect(other)}")

  @doc false
  @spec invalid!(String.t(), String.t()) :: no_return()
  def invalid!(field, message) do
    raise Ash.Error.Invalid.exception(
            errors: [Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)]
          )
  end

  # proto field name => {kind, ash name} for record message fields
  defp record_fields(nil), do: %{}

  defp record_fields(%IR.Message{fields: fields}) do
    for %IR.Field{name: name, source: {kind, _resource, ash_name}} <- fields,
        kind in [:attribute, :calculation, :aggregate, :relationship],
        into: %{},
        do: {name, {kind, ash_name}}
  end

  defp mask_paths(request, key) do
    case Map.get(request, key) do
      %{paths: [_ | _] = paths} -> paths
      _ -> nil
    end
  end

  defp top(path), do: path |> String.split(".") |> hd()

  defp load_name({name, _}), do: name
  defp load_name(name), do: name
end
