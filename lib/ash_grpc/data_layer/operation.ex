defmodule AshGrpc.DataLayer.Operation do
  @moduledoc """
  An rpc of a remote resource (the `read`, `get`, `create`, `update` and `destroy` entities of
  the `grpc_remote` section, see `AshGrpc.DataLayer`).
  """

  defstruct [
    :kind,
    :rpc,
    :actions,
    :records,
    :request,
    :response,
    :update_mask,
    :__spark_metadata__,
    by: [],
    filter: [],
    paginate: :page_token,
    page_size_field: :page_size,
    page_token_field: :page_token,
    next_page_token_field: :next_page_token
  ]

  @type kind :: :read | :get | :create | :update | :destroy

  @type t :: %__MODULE__{
          kind: kind(),
          rpc: atom() | String.t(),
          actions: [atom()] | nil,
          by: [atom()],
          filter: [atom() | {atom(), atom() | String.t()}],
          paginate: :page_token | :none,
          records: atom() | String.t() | nil,
          page_size_field: atom() | String.t(),
          page_token_field: atom() | String.t(),
          next_page_token_field: atom() | String.t(),
          request: atom() | String.t() | nil,
          response: atom() | String.t() | [atom() | String.t()] | nil,
          update_mask: atom() | String.t() | nil,
          __spark_metadata__: term()
        }
end
