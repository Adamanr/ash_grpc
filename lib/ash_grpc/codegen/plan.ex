defmodule AshGrpc.Codegen.Plan do
  @moduledoc """
  The result of `AshGrpc.Codegen.plan/1`: what codegen would write and delete.

    * `:schema` – the generated IR (numbers assigned)
    * `:lock` – the updated lock
    * `:changes` – `AshGrpc.Proto.Diff` changes from the last snapshots to `:schema`
    * `:files` – every output with its new contents and a `:status`
      (`:created`, `:updated` or `:unchanged`); `:kind` is `:proto`, `:snapshot`, `:lock`
      or `:buf`
    * `:deletes` – stale generated files to remove
  """

  alias AshGrpc.Proto.{Diff, IR, Lock}

  defstruct schema: nil, lock: nil, changes: [], files: [], deletes: []

  @type output :: %{
          kind: :proto | :snapshot | :lock | :buf,
          path: Path.t(),
          contents: String.t(),
          status: :created | :updated | :unchanged
        }

  @type t :: %__MODULE__{
          schema: IR.Schema.t(),
          lock: Lock.t(),
          changes: [Diff.Change.t()],
          files: [output()],
          deletes: [%{kind: :proto | :snapshot, path: Path.t()}]
        }

  @doc "Outputs that would be created or updated."
  @spec pending_files(t()) :: [output()]
  def pending_files(%__MODULE__{files: files}), do: Enum.reject(files, &(&1.status == :unchanged))

  @doc "Whether applying the plan would change anything on disk."
  @spec changed?(t()) :: boolean()
  def changed?(%__MODULE__{} = plan), do: pending_files(plan) != [] or plan.deletes != []

  @doc "Whether the plan contains breaking changes."
  @spec breaking?(t()) :: boolean()
  def breaking?(%__MODULE__{changes: changes}), do: Diff.breaking?(changes)

  @doc "One line per pending write or delete: `created priv/protos/...`."
  @spec summary(t()) :: [String.t()]
  def summary(%__MODULE__{} = plan) do
    Enum.map(pending_files(plan), &"#{&1.status} #{&1.path}") ++
      Enum.map(plan.deletes, &"deleted #{&1.path}")
  end
end
