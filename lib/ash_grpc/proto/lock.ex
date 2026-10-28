defmodule AshGrpc.Proto.Lock do
  @moduledoc """
  Field-number lock: keeps wire numbers stable across code changes.

  Protobuf compatibility depends on field/enum numbers never changing and never
  being reused. Users may pin numbers explicitly in the DSL; everything else is
  assigned once and recorded in a lock file (`priv/grpc/ash_grpc.lock.json` by
  default, committed to git). Removed fields become `reserved` automatically.

  ## File format (version 1)

      {
        "version": 1,
        "messages": {
          "myapp.accounts.v1.User": {
            "fields": {"id": 1, "email": 2},
            "reserved_numbers": [3, [10, 12], [1000, "max"]],
            "reserved_names": ["legacy_name"]
          }
        },
        "enums": {
          "myapp.accounts.v1.UserRole": {
            "values": {"USER_ROLE_UNSPECIFIED": 0, "USER_ROLE_ADMIN": 1},
            "reserved_numbers": [],
            "reserved_names": []
          }
        }
      }

  Reserved numbers are single numbers or inclusive `[from, to]` ranges (`"max"`
  as upper bound). `write!/2` output is stable: keys of `messages`/`enums` are
  sorted, fields/values are sorted by number (then name), reserved numbers are
  sorted and reserved names sorted alphabetically.

  ## Assignment rules (`assign/2`)

  For every message (recursively, including nested messages) and every enum
  (top-level and nested) of the file:

    1. explicit numbers in the IR always win
    2. otherwise the number recorded in the lock for that name is reused
    3. otherwise the lowest free number is taken: not used by another
       field/value, not reserved (in the IR or in the lock), not locked for a
       removed field, and for fields not in `19000..19999` (reserved by the
       protobuf implementation). An enum value named `*_UNSPECIFIED` without a
       number gets `0` when it is free; other enum values start at `1`.
    4. fields/values recorded in the lock but missing from the IR are removed:
       their numbers and names are added to the reserved numbers/names of both
       the lock and the returned IR. A number that moved (explicit number for a
       name that had a different locked number) reserves the old number only.
    5. the reserved numbers/names of the returned IR node and of the lock entry
       are the union of the IR's and the lock's (so a `reserved` removed from the
       DSL is still honoured); the lock never forgets reservations

  Map entry messages are not locked (their key/value numbers are fixed). Lock
  entries of messages/enums that are not part of the file are kept untouched.

  ## Errors

  Conflicts are programming errors in the schema definition, so `assign/2`
  **raises** `AshGrpc.Proto.Lock.ConflictError` after collecting every conflict
  of the file (the exception has an `:errors` list and a message listing all of
  them). Conflicts are:

    * an explicit number that is reserved, out of range, or inside `19000..19999`
    * an explicit number that the lock assigns to another (removed or renamed)
      field/value – reusing it would break the wire format
    * two fields (or two enum values without `allow_alias`) with the same number
    * a field/value whose name is reserved
    * duplicate field/value names
  """

  alias AshGrpc.Proto.IR

  defstruct version: 1, messages: %{}, enums: %{}

  @type entry :: %{
          optional(:fields) => %{String.t() => pos_integer()},
          optional(:values) => %{String.t() => integer()},
          reserved_numbers: [IR.reserved_number()],
          reserved_names: [String.t()]
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          messages: %{IR.full_name() => entry()},
          enums: %{IR.full_name() => entry()}
        }

  @version 1
  @max_field 536_870_911
  @max_enum 2_147_483_647
  @implementation_reserved 19_000..19_999

  defmodule ConflictError do
    @moduledoc "Raised by `AshGrpc.Proto.Lock.assign/2` when explicit numbers conflict with the lock."
    defexception errors: []

    @type t :: %__MODULE__{errors: [String.t()]}

    @impl true
    def message(%{errors: errors}) do
      "field number conflicts:\n" <> Enum.map_join(errors, "\n", &("  * " <> &1))
    end
  end

  @doc "Default lock path for an otp app."
  @spec default_path(atom()) :: Path.t()
  def default_path(_otp_app), do: Path.join(["priv", "grpc", "ash_grpc.lock.json"])

  @doc "Loads a lock file. A missing file yields an empty lock."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    case Elixir.File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> {:ok, %__MODULE__{}}
      {:error, reason} -> {:error, {:read, path, reason}}
    end
  end

  @doc "Decodes the JSON contents of a lock file."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) do
    with {:ok, data} <- Jason.decode(json),
         :ok <- check_version(data),
         {:ok, messages} <- decode_entries(data["messages"] || %{}, "fields", :fields),
         {:ok, enums} <- decode_entries(data["enums"] || %{}, "values", :values) do
      {:ok, %__MODULE__{version: @version, messages: messages, enums: enums}}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Writes a lock file (deterministic, pretty-printed JSON, trailing newline)."
  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{} = lock, path) do
    Elixir.File.mkdir_p!(Path.dirname(path))
    Elixir.File.write!(path, encode(lock))
  end

  @doc "Encodes a lock as the deterministic JSON written by `write!/2`."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = lock) do
    data =
      Jason.OrderedObject.new(
        version: @version,
        messages: encode_entries(lock.messages, "fields", :fields),
        enums: encode_entries(lock.enums, "values", :values)
      )

    Jason.encode!(data, pretty: true) <> "\n"
  end

  @doc """
  Assigns numbers to every field with `number: nil` in the file's messages
  (recursively) and to every enum value with `number: nil`, using the lock
  first and then the next free number. Explicit numbers in the IR always win.
  Fields/values missing from the IR are reserved. Returns the updated file and
  lock. See the module docs for the full rules; raises
  `AshGrpc.Proto.Lock.ConflictError` on conflicts.
  """
  @spec assign(IR.File.t(), t()) :: {IR.File.t(), t()}
  def assign(%IR.File{} = file, %__MODULE__{} = lock) do
    {messages, acc} = Enum.map_reduce(file.messages, {lock, []}, &assign_message/2)
    {enums, {lock, errors}} = Enum.map_reduce(file.enums, acc, &assign_enum/2)

    case errors do
      [] -> {%{file | messages: messages, enums: enums}, lock}
      errors -> raise ConflictError, errors: errors
    end
  end

  # -- messages -----------------------------------------------------------------------------

  defp assign_message(%IR.Message{} = message, {lock, errors}) do
    entry = Map.get(lock.messages, message.full_name, empty_entry(:fields))

    {numbered, entry, new_errors} =
      assign_numbers(message.fields, entry, %{
        kind: :field,
        path: message.full_name,
        locked: entry.fields,
        reserved_numbers: message.reserved_numbers,
        reserved_names: message.reserved_names,
        allow_alias?: false,
        first_free: 1
      })

    entry = %{entry | fields: Map.new(numbered, &{&1.name, &1.number})}
    lock = %{lock | messages: Map.put(lock.messages, message.full_name, entry)}

    acc = {lock, errors ++ new_errors}
    {nested, acc} = Enum.map_reduce(message.nested_messages, acc, &assign_message/2)
    {nested_enums, acc} = Enum.map_reduce(message.nested_enums, acc, &assign_enum/2)

    message = %{
      message
      | fields: numbered,
        nested_messages: nested,
        nested_enums: nested_enums,
        reserved_numbers: entry.reserved_numbers,
        reserved_names: entry.reserved_names
    }

    {message, acc}
  end

  # -- enums --------------------------------------------------------------------------------

  defp assign_enum(%IR.Enum{} = enum, {lock, errors}) do
    entry = Map.get(lock.enums, enum.full_name, empty_entry(:values))

    {numbered, entry, new_errors} =
      assign_numbers(enum.values, entry, %{
        kind: :enum_value,
        path: enum.full_name,
        locked: entry.values,
        reserved_numbers: enum.reserved_numbers,
        reserved_names: enum.reserved_names,
        allow_alias?: enum.allow_alias?,
        first_free: 1
      })

    entry = %{entry | values: Map.new(numbered, &{&1.name, &1.number})}
    lock = %{lock | enums: Map.put(lock.enums, enum.full_name, entry)}

    enum = %{
      enum
      | values: numbered,
        reserved_numbers: entry.reserved_numbers,
        reserved_names: entry.reserved_names
    }

    {enum, {lock, errors ++ new_errors}}
  end

  # -- shared numbering ---------------------------------------------------------------------

  # `items` are IR fields or enum values (both have `name` and `number`).
  defp assign_numbers(items, entry, cfg) do
    reserved_numbers = normalize_numbers(cfg.reserved_numbers ++ entry.reserved_numbers)
    reserved_names = normalize_names(cfg.reserved_names ++ entry.reserved_names)
    names = MapSet.new(items, & &1.name)

    errors =
      duplicate_name_errors(items, cfg) ++
        reserved_name_errors(items, reserved_names, cfg) ++
        explicit_number_errors(items, reserved_numbers, cfg)

    # numbers the lock gave to names that are still present keep their meaning;
    # numbers of removed names must not be reused either (they get reserved below)
    taken =
      items
      |> Enum.map(& &1.number)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.values(cfg.locked)))

    {numbered, _taken} =
      Enum.map_reduce(items, taken, fn item, taken ->
        number =
          item.number || cfg.locked[item.name] ||
            default_number(item, taken, reserved_numbers, cfg)

        {%{item | number: number}, MapSet.put(taken, number)}
      end)

    exhausted =
      for %{number: nil, name: name} <- numbered,
          do:
            "#{label(cfg, name)}: no free number left (everything up to max is reserved or used)"

    numbered_ok = Enum.reject(numbered, &is_nil(&1.number))

    errors =
      errors ++
        exhausted ++
        locked_number_errors(items, reserved_numbers, cfg) ++
        duplicate_number_errors(numbered_ok, cfg)

    {freed_numbers, freed_names} = freed(cfg.locked, names, numbered)

    entry = %{
      entry
      | reserved_numbers: normalize_numbers(reserved_numbers ++ freed_numbers),
        reserved_names: normalize_names(reserved_names ++ freed_names)
    }

    {numbered, entry, errors}
  end

  # Names that disappeared reserve their number (unless an alias still uses it)
  # and their name; names whose number moved reserve the old number only.
  defp freed(locked, names, numbered) do
    final_numbers = MapSet.new(numbered, & &1.number)

    Enum.reduce(locked, {[], []}, fn {name, number}, {numbers, removed} ->
      # a number still in use (unchanged, or kept by an alias) is not freed
      numbers = if MapSet.member?(final_numbers, number), do: numbers, else: [number | numbers]
      removed = if MapSet.member?(names, name), do: removed, else: [name | removed]
      {numbers, removed}
    end)
  end

  defp default_number(item, taken, reserved, %{kind: :enum_value} = cfg) do
    if String.ends_with?(item.name, "_UNSPECIFIED") and free?(0, taken, reserved),
      do: 0,
      else: next_free(cfg.first_free, taken, reserved, cfg)
  end

  defp default_number(_item, taken, reserved, cfg),
    do: next_free(cfg.first_free, taken, reserved, cfg)

  # Lowest free number >= candidate; jumps over reserved ranges. nil when none is left.
  defp next_free(candidate, taken, reserved, cfg) do
    cond do
      candidate > max_number(cfg) ->
        nil

      cfg.kind == :field and candidate in @implementation_reserved ->
        next_free(Enum.max(@implementation_reserved) + 1, taken, reserved, cfg)

      range_end = reserved_range_end(candidate, reserved) ->
        if range_end == :max, do: nil, else: next_free(range_end + 1, taken, reserved, cfg)

      MapSet.member?(taken, candidate) ->
        next_free(candidate + 1, taken, reserved, cfg)

      true ->
        candidate
    end
  end

  defp reserved_range_end(number, reserved) do
    Enum.find_value(reserved, fn
      {from, :max} when number >= from -> :max
      {from, to} when number >= from and number <= to -> to
      ^number -> number
      _ -> nil
    end)
  end

  defp max_number(%{kind: :field}), do: @max_field
  defp max_number(%{kind: :enum_value}), do: @max_enum

  defp free?(number, taken, reserved),
    do: not MapSet.member?(taken, number) and not reserved?(number, reserved)

  defp explicit_number_errors(items, reserved, cfg) do
    for %{number: number, name: name} <- items,
        not is_nil(number),
        error =
          range_error(number, cfg) || reserved_error(number, reserved) ||
            owner_error(name, number, items, cfg),
        do: "#{label(cfg, name)}: #{error}"
  end

  defp range_error(number, %{kind: :field}) when number < 1 or number > @max_field,
    do: "number #{number} is out of range (1..#{@max_field})"

  defp range_error(number, %{kind: :field}) when number in @implementation_reserved,
    do: "number #{number} is in the range 19000..19999 reserved by protobuf"

  defp range_error(_number, _cfg), do: nil

  defp reserved_error(number, reserved),
    do: if(reserved?(number, reserved), do: "number #{number} is reserved")

  # The item's own locked number is always fine (also for enum aliases); a number
  # locked for another name that does not keep it is a reuse.
  defp owner_error(name, number, items, cfg) do
    owner =
      cfg.locked[name] != number &&
        Enum.find_value(cfg.locked, fn {locked_name, locked_number} ->
          if locked_number == number and locked_name != name and
               not alias_still_present?(locked_name, number, items, cfg),
             do: locked_name
        end)

    if owner,
      do:
        "number #{number} is locked for #{inspect(owner)}; " <>
          "reusing it breaks the wire format (pick another number)"
  end

  # A locked number for a name without explicit number that is now reserved
  # (e.g. the DSL added a `reserved` for it) cannot be honoured.
  defp locked_number_errors(items, reserved, cfg) do
    for %{number: nil, name: name} <- items,
        number = cfg.locked[name],
        number != nil and reserved?(number, reserved),
        do: "#{label(cfg, name)}: locked number #{number} is reserved"
  end

  defp alias_still_present?(locked_name, number, items, cfg) do
    cfg.allow_alias? and
      Enum.any?(items, &(&1.name == locked_name and (&1.number || number) == number))
  end

  defp duplicate_number_errors(_numbered, %{allow_alias?: true}), do: []

  defp duplicate_number_errors(numbered, cfg) do
    numbered
    |> Enum.group_by(& &1.number)
    |> Enum.filter(fn {_number, items} -> length(items) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {number, items} ->
      "#{cfg.path}: number #{number} is used by #{Enum.map_join(items, ", ", &inspect(&1.name))}"
    end)
  end

  defp duplicate_name_errors(items, cfg) do
    items
    |> Enum.frequencies_by(& &1.name)
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {name, _} -> "#{label(cfg, name)}: duplicate name" end)
  end

  defp reserved_name_errors(items, reserved_names, cfg) do
    items
    |> Enum.filter(&(&1.name in reserved_names))
    |> Enum.map(&"#{label(cfg, &1.name)}: name is reserved")
  end

  defp label(%{kind: :field, path: path}, name), do: "field #{path}.#{name}"
  defp label(%{kind: :enum_value, path: path}, name), do: "enum value #{path}.#{name}"

  # -- reserved helpers ---------------------------------------------------------------------

  @doc "Returns true if `number` is covered by the reserved numbers/ranges."
  @spec reserved?(integer(), [IR.reserved_number()]) :: boolean()
  def reserved?(number, reserved) do
    Enum.any?(reserved, fn
      {from, :max} -> number >= from
      {from, to} -> number >= from and number <= to
      single -> number == single
    end)
  end

  # Sorted, de-duplicated; singles covered by a range are dropped.
  defp normalize_numbers(numbers) do
    {ranges, singles} = numbers |> Enum.uniq() |> Enum.split_with(&is_tuple/1)
    singles = Enum.reject(singles, &reserved?(&1, ranges))

    Enum.sort_by(singles ++ ranges, fn
      {from, :max} -> {from, :infinity}
      {from, to} -> {from, to}
      single -> {single, single}
    end)
  end

  defp normalize_names(names), do: names |> Enum.uniq() |> Enum.sort()

  defp empty_entry(key), do: %{key => %{}, reserved_numbers: [], reserved_names: []}

  # -- JSON ---------------------------------------------------------------------------------

  defp check_version(%{"version" => @version}), do: :ok
  defp check_version(%{"version" => other}), do: {:error, {:unsupported_version, other}}
  defp check_version(_), do: {:error, :missing_version}

  defp decode_entries(entries, numbers_key, key) when is_map(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {full_name, data}, {:ok, acc} ->
      with true <- is_map(data),
           {:ok, numbers} <- decode_numbers(data[numbers_key] || %{}),
           {:ok, reserved} <- decode_reserved(data["reserved_numbers"] || []),
           {:ok, names} <- decode_names(data["reserved_names"] || []) do
        entry = %{
          key => numbers,
          reserved_numbers: normalize_numbers(reserved),
          reserved_names: normalize_names(names)
        }

        {:cont, {:ok, Map.put(acc, full_name, entry)}}
      else
        _ -> {:halt, {:error, {:invalid_entry, full_name}}}
      end
    end)
  end

  defp decode_entries(_entries, _numbers_key, _key), do: {:error, :invalid_entries}

  defp decode_numbers(map) when is_map(map) do
    if Enum.all?(map, fn {name, number} -> is_binary(name) and is_integer(number) end),
      do: {:ok, map},
      else: :error
  end

  defp decode_numbers(_), do: :error

  defp decode_reserved(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn
      number, {:ok, acc} when is_integer(number) ->
        {:cont, {:ok, [number | acc]}}

      [from, "max"], {:ok, acc} when is_integer(from) ->
        {:cont, {:ok, [{from, :max} | acc]}}

      [from, to], {:ok, acc} when is_integer(from) and is_integer(to) and from <= to ->
        {:cont, {:ok, [{from, to} | acc]}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, numbers} -> {:ok, Enum.reverse(numbers)}
      :error -> :error
    end
  end

  defp decode_reserved(_), do: :error

  defp decode_names(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error
  end

  defp decode_names(_), do: :error

  defp encode_entries(entries, numbers_key, key) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {full_name, entry} ->
      numbers =
        entry
        |> Map.get(key, %{})
        |> Enum.sort_by(fn {name, number} -> {number, name} end)
        |> Jason.OrderedObject.new()

      {full_name,
       Jason.OrderedObject.new([
         {numbers_key, numbers},
         {"reserved_numbers",
          entry
          |> Map.get(:reserved_numbers, [])
          |> normalize_numbers()
          |> Enum.map(&encode_reserved/1)},
         {"reserved_names", entry |> Map.get(:reserved_names, []) |> normalize_names()}
       ])}
    end)
    |> Jason.OrderedObject.new()
  end

  defp encode_reserved({from, :max}), do: [from, "max"]
  defp encode_reserved({from, to}), do: [from, to]
  defp encode_reserved(number), do: number
end
