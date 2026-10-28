defmodule AshGrpc.Schema do
  @moduledoc """
  Builds the protobuf IR (`AshGrpc.Proto.IR.Schema`) from Ash domains using `AshGrpc.Domain`.

  One `.proto` file is built per domain. It contains:

    * a record message per resource using `AshGrpc.Resource` (attributes, calculations,
      aggregates and relationships listed in `fields`),
    * a message per embedded resource referenced by those resources (placed in the file of the
      first domain that references it),
    * request/response messages per rpc (DESIGN.md §4.4),
    * messages/enums required by type mappings (deduplicated by `full_name` across the schema),
    * one service per service name (see `AshGrpc.Domain.Service`).

  Field numbers that are not explicit are assigned by `AshGrpc.Proto.Lock.assign/2` from
  `opts[:lock]` (an empty lock when `nil`).

  ## Ownership of resource messages

  The schema builder owns the messages of resources and embedded resources. It passes
  `resolve_resource: fn resource -> full_name | nil end` to `AshGrpc.Type.Mapping.to_proto/3`,
  which returns `{:message, full_name}` for resources nested in other types.

  ## `source` values

  Messages:

    * `{:resource, resource}` / `{:embedded, resource}` – record messages
    * `{:action_input, resource, action}` / `{:action_output, resource, action}` – rpc messages
    * whatever `AshGrpc.Type.Mapping` sets for generated type messages/enums

  Fields:

    * `{:attribute | :calculation | :aggregate | :relationship, resource, name}`
    * `{:argument, resource, action, name}`
    * `{:special, name}` for generated fields: `:page_size`, `:page_token`, `:filter`,
      `:order_by`, `:read_mask`, `:update_mask`, `:items`, `:next_page_token`, `:total_size`,
      `:record` (wrapped input), `:value` (wrapped generic action result), `:count`, `:errors`

  Rpcs: `{:action, resource, action_name, %AshGrpc.Resource.Rpc{}}` with `kind` and `get_by`
  resolved. Services and files: `{:domain, domain}`.
  """

  alias AshGrpc.Proto.{IR, Lock}

  @doc """
  Builds the IR schema for the given domains.

  ## Options

    * `:lock` – an `AshGrpc.Proto.Lock` used to assign field numbers (default: empty lock)
  """
  @spec build([module()], Keyword.t()) :: {:ok, IR.Schema.t()} | {:error, [Exception.t()]}
  def build(domains, opts \\ []) do
    case build_with_lock(domains, opts) do
      {:ok, schema, _lock} -> {:ok, schema}
      {:error, errors} -> {:error, errors}
    end
  end

  @doc """
  Like `build/2`, but also returns the lock updated with the assigned numbers
  (for `mix ash_grpc.codegen`, which writes it).
  """
  @spec build_with_lock([module()], Keyword.t()) ::
          {:ok, IR.Schema.t(), Lock.t()} | {:error, [Exception.t()]}
  def build_with_lock(domains, opts \\ []) do
    lock = opts[:lock] || %Lock{}

    with {:ok, files} <- AshGrpc.Schema.Builder.files(List.wrap(domains)) do
      {files, lock} = Enum.map_reduce(files, lock, &Lock.assign/2)
      {:ok, %IR.Schema{files: files}, lock}
    end
  end
end
