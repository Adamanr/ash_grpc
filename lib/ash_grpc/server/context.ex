defmodule AshGrpc.Server.Context do
  @moduledoc """
  Everything the server knows about the rpc being handled. Passed to
  `AshGrpc.Server.RpcHandler` implementations.

    * `endpoint`, `schema` – the endpoint and its `AshGrpc.Proto.IR.Schema`
    * `service` – full name of the service, `rpc` – the `IR.Rpc`
    * `input` / `output` – the `IR.Message` of the request / response (`nil` for messages
      outside the schema, e.g. `google.protobuf.Empty` or hand-written modules);
      `input_module` / `output_module` – their Elixir modules
    * `record` – the `IR.Message` of the resource's record
    * `resource`, `action` (the `Ash.Resource.Actions` struct), `domain`, `config` (the
      `AshGrpc.Resource.Rpc` DSL entity), `kind`
    * `actor`, `tenant`, `context` – set by interceptors (see `AshGrpc.Server`)
    * `timeout` – milliseconds left until the incoming deadline (`nil` without deadline)
    * `metadata` – request headers
    * `stream` – the `GRPC.Server.Stream`
  """

  defstruct [
    :endpoint,
    :schema,
    :service,
    :rpc,
    :input,
    :output,
    :input_module,
    :output_module,
    :record,
    :resource,
    :action,
    :domain,
    :config,
    :kind,
    :actor,
    :tenant,
    :timeout,
    :stream,
    :settings,
    context: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          endpoint: module(),
          schema: AshGrpc.Proto.IR.Schema.t(),
          service: String.t(),
          rpc: AshGrpc.Proto.IR.Rpc.t(),
          input: AshGrpc.Proto.IR.Message.t() | nil,
          output: AshGrpc.Proto.IR.Message.t() | nil,
          input_module: module(),
          output_module: module(),
          record: AshGrpc.Proto.IR.Message.t() | nil,
          resource: module(),
          action: struct(),
          domain: module(),
          config: AshGrpc.Resource.Rpc.t(),
          kind: AshGrpc.Resource.Rpc.kind(),
          actor: term(),
          tenant: term(),
          timeout: non_neg_integer() | nil,
          stream: GRPC.Server.Stream.t(),
          settings: map(),
          context: map(),
          metadata: map()
        }

  @doc false
  @spec new(module(), map(), GRPC.Server.Stream.t()) :: t()
  def new(endpoint, info, stream) do
    timeout =
      case GRPC.Server.Stream.remaining_ms(stream) do
        :infinity -> nil
        ms -> ms
      end

    %__MODULE__{
      endpoint: endpoint,
      schema: endpoint.schema(),
      service: info.service,
      rpc: info.rpc,
      input: info.input,
      output: info.output,
      input_module: info.input_module,
      output_module: info.output_module,
      record: info.record,
      resource: info.resource,
      action: Ash.Resource.Info.action(info.resource, info.action),
      domain: info.domain,
      config: info.config,
      kind: info.config.kind,
      actor: AshGrpc.Server.actor(stream),
      tenant: AshGrpc.Server.tenant(stream),
      context: AshGrpc.Server.context(stream),
      timeout: timeout,
      stream: stream,
      settings: endpoint.__ash_grpc__(:config),
      metadata: metadata(stream)
    }
  end

  @doc """
  The request metadata (headers) of a server stream: lowercase keys, `-bin` values decoded.
  """
  @spec metadata(GRPC.Server.Stream.t()) :: %{String.t() => String.t()}
  def metadata(%GRPC.Server.Stream{http_request_headers: headers}) when is_map(headers),
    do: GRPC.Transport.HTTP2.decode_headers(headers)

  def metadata(_stream), do: %{}

  @doc """
  Options for `Ash.*.for_*` functions (`actor`, `tenant`, `context`).
  """
  @spec input_opts(t()) :: Keyword.t()
  def input_opts(%__MODULE__{} = ctx) do
    [
      actor: ctx.actor,
      tenant: ctx.tenant,
      context: Map.put(ctx.context, :ash_grpc, %{rpc: ctx.rpc.name, service: ctx.service})
    ]
  end

  @doc """
  Options for Ash calls (`Ash.read/2`, `Ash.create/2`, ...): `actor`, `tenant`, `domain` and the
  remaining deadline as `timeout`.
  """
  @spec call_opts(t()) :: Keyword.t()
  def call_opts(%__MODULE__{} = ctx) do
    opts = [actor: ctx.actor, tenant: ctx.tenant, domain: ctx.domain]
    if ctx.timeout, do: Keyword.put(opts, :timeout, ctx.timeout), else: opts
  end
end
