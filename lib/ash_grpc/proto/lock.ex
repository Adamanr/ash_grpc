defmodule AshGrpc.Proto.Lock do
  @moduledoc """
  Field-number lock: keeps wire numbers stable across code changes.

  Protobuf compatibility depends on field/enum numbers never changing and never
  being reused. Users may pin numbers explicitly in the DSL; everything else is
  assigned once and recorded in a lock file (`priv/grpc/ash_grpc.lock.json` by
  default, committed to git). Removed fields become `reserved` automatically.

  > #### Foundation implementation {: .warning}
  >
  > `assign/2` currently only fills missing numbers sequentially and keeps
  > numbers already present in the lock. Loading/writing the file, reserving
  > removed fields/names and enum values are owned by the "proto toolkit" work
  > package (see DESIGN.md). The public contract below is stable.

  ## File format (version 1)

      {
        "version": 1,
        "messages": {
          "myapp.accounts.v1.User": {
            "fields": {"id": 1, "email": 2},
            "reserved_numbers": [3],
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

  @doc "Default lock path for an otp app."
  @spec default_path(atom()) :: Path.t()
  def default_path(_otp_app), do: Path.join(["priv", "grpc", "ash_grpc.lock.json"])

  @doc "Loads a lock file. A missing file yields an empty lock."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    if Elixir.File.exists?(path) do
      {:error, :not_implemented}
    else
      {:ok, %__MODULE__{}}
    end
  end

  @doc "Writes a lock file (deterministic, pretty-printed JSON)."
  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{}, _path),
    do: raise("AshGrpc.Proto.Lock.write!/2 is not implemented yet")

  @doc """
  Assigns numbers to every field with `number: nil` in the file's messages
  (recursively), using the lock first and then the next free number.
  Explicit numbers in the IR always win. Returns the updated file and lock.
  """
  @spec assign(IR.File.t(), t()) :: {IR.File.t(), t()}
  def assign(%IR.File{} = file, %__MODULE__{} = lock) do
    {messages, lock} = Enum.map_reduce(file.messages, lock, &assign_message/2)
    {%{file | messages: messages}, lock}
  end

  defp assign_message(%IR.Message{} = message, lock) do
    locked = get_in(lock.messages, [message.full_name, :fields]) || %{}

    used =
      message.fields
      |> Enum.map(&(&1.number || locked[&1.name]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {fields, _used} =
      Enum.map_reduce(message.fields, used, fn field, used ->
        number = field.number || locked[field.name] || next_free(used)
        {%{field | number: number}, MapSet.put(used, number)}
      end)

    {nested, lock} = Enum.map_reduce(message.nested_messages, lock, &assign_message/2)

    entry = %{
      fields: Map.new(fields, &{&1.name, &1.number}),
      reserved_numbers: message.reserved_numbers,
      reserved_names: message.reserved_names
    }

    lock = %{lock | messages: Map.put(lock.messages, message.full_name, entry)}
    {%{message | fields: fields, nested_messages: nested}, lock}
  end

  # 19000..19999 are reserved by the protobuf implementation.
  defp next_free(used, candidate \\ 1) do
    cond do
      candidate in 19_000..19_999 -> next_free(used, 20_000)
      MapSet.member?(used, candidate) -> next_free(used, candidate + 1)
      true -> candidate
    end
  end
end
