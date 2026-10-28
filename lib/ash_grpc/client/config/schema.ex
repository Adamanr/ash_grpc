defmodule AshGrpc.Client.Config.Schema do
  @moduledoc false

  @statuses [
    :cancelled,
    :unknown,
    :invalid_argument,
    :deadline_exceeded,
    :not_found,
    :already_exists,
    :permission_denied,
    :resource_exhausted,
    :failed_precondition,
    :aborted,
    :out_of_range,
    :unimplemented,
    :internal,
    :unavailable,
    :data_loss,
    :unauthenticated
  ]

  def retry_schema do
    [
      max_attempts: [
        type: :pos_integer,
        default: 3,
        doc: "Total number of attempts, including the first one."
      ],
      backoff: [
        type: {:custom, AshGrpc.Client.Config, :validate_backoff, []},
        default: {:exponential, 50, 2_000},
        doc:
          "`{:exponential, base_ms, max_ms}`: delay before attempt `n` is `min(max, base * 2^(n-1))`."
      ],
      jitter: [
        type: :boolean,
        default: true,
        doc: "Apply full jitter (a uniformly random delay between 0 and the computed backoff)."
      ],
      on: [
        type: {:list, {:in, @statuses}},
        default: [:unavailable],
        doc: "gRPC status codes (snake_case atoms) that trigger a retry."
      ]
    ]
  end

  def schema do
    [
      name: [
        type: :atom,
        doc:
          "Name the client is registered under. Defaults to the client module; required for dynamic clients started with `AshGrpc.Client.start_link/1`."
      ],
      otp_app: [
        type: :atom,
        doc: "The OTP application whose environment holds the configuration."
      ],
      services: [
        type: {:list, :atom},
        required: true,
        doc: "`GRPC.Service` modules (`use GRPC.Service`) whose rpcs this client can call."
      ],
      address: [
        type: :string,
        doc:
          ~s(Target to connect to: `"host:port"`, `"dns:///host:port"`, `"ipv4:10.0.0.1:50051,10.0.0.2:50051"`, `"unix:/path.sock"`, `"https://host:port"` … Required unless `sandbox: true`.)
      ],
      tls: [
        type: {:custom, AshGrpc.Client.Config, :validate_tls, []},
        default: false,
        doc:
          "`false` (plaintext), `true` (TLS verified against the OS trust store), an `:ssl` keyword list (`cacertfile`, `certfile`, `keyfile` for mTLS, …) or a `GRPC.Credential`."
      ],
      pool_size: [
        type: :pos_integer,
        default: 1,
        doc:
          "Number of independent HTTP/2 connections; calls are distributed round-robin. Each connection itself balances across resolved addresses (see `:lb_policy`)."
      ],
      connect: [
        type: {:in, [:eager, :lazy]},
        default: :eager,
        doc:
          "`:eager` dials every connection when the client starts (in the background, never blocking or failing the supervisor); `:lazy` dials a connection on its first use."
      ],
      connect_timeout: [
        type: :pos_integer,
        default: 5_000,
        doc:
          "How long a call waits for a not-yet-established connection before failing with `UNAVAILABLE` (also bounded by the call deadline)."
      ],
      lb_policy: [
        type: {:in, [:round_robin, :pick_first]},
        default: :round_robin,
        doc: "Load-balancing policy across the addresses a target resolves to."
      ],
      reconnect_attempts: [
        type: {:or, [:non_neg_integer, {:in, [:infinity]}]},
        default: :infinity,
        doc:
          "How many times a dropped connection is re-dialed (exponential backoff with jitter) before it is considered dead."
      ],
      deadline: [
        type: :pos_integer,
        default: 10_000,
        doc:
          "Default deadline in milliseconds. A deadline is always sent (`grpc-timeout`); it covers all retry attempts of a call."
      ],
      retry: [
        type: {:custom, AshGrpc.Client.Config, :validate_retry, []},
        default: false,
        doc: """
        Retry policy: `false` (default) or a keyword list. Only idempotent rpcs are retried (see
        `:idempotent`). Keys:

        #{Spark.Options.docs(retry_schema())}
        """
      ],
      idempotent: [
        type: {:list, {:or, [:atom, :string]}},
        default: [],
        doc:
          "Rpcs (any accepted name form) to treat as idempotent in addition to those whose service descriptor declares `idempotency_level` `NO_SIDE_EFFECTS`/`IDEMPOTENT`."
      ],
      metadata: [
        type: {:custom, AshGrpc.Client.Config, :validate_metadata, []},
        default: %{},
        doc:
          "Metadata sent with every call: a map/keyword list, a `{module, function, args}` (called as `apply(module, function, [context | args])`) or a function of arity 0 or 1 (receiving the context). The context is a map with `:client`, `:service`, `:rpc` and `:opts` (the call options, e.g. `:actor`). Per-call `metadata:` is merged on top."
      ],
      compression: [
        type: {:or, [{:in, [nil, :gzip]}, :atom]},
        doc: "Compress requests: `:gzip` or a `GRPC.Compressor` module."
      ],
      max_message_size: [
        type: :pos_integer,
        doc: "Default for both `:max_send_message_size` and `:max_receive_message_size`."
      ],
      max_send_message_size: [
        type: :pos_integer,
        doc:
          "Requests larger than this (in encoded bytes) fail locally with `RESOURCE_EXHAUSTED`."
      ],
      max_receive_message_size: [
        type: :pos_integer,
        doc:
          "Responses larger than this (in encoded bytes) fail with `RESOURCE_EXHAUSTED`. When set, interceptors see undecoded responses (`AshGrpc.Client.Codec`)."
      ],
      interceptors: [
        type: {:list, :any},
        default: [],
        doc: "`GRPC.Client.Interceptor` modules or `{module, opts}` tuples."
      ],
      adapter: [
        type: :atom,
        default: GRPC.Client.Adapters.Mint,
        doc: "The `GRPC.Client.Adapter` used for the transport."
      ],
      adapter_opts: [
        type: :keyword_list,
        default: [],
        doc: "Options passed to the adapter's `connect/2`."
      ],
      codec: [
        type: :atom,
        default: GRPC.Codec.Proto,
        doc: "The `GRPC.Codec` used to encode messages."
      ],
      sandbox: [
        type: :boolean,
        default: false,
        doc:
          "Route calls to `AshGrpc.Client.Sandbox` instead of the network (typically in `config/test.exs`). No connection is opened."
      ],
      map_errors: [
        type: :boolean,
        default: true,
        doc:
          "Map `GRPC.RPCError`s into Ash errors through `AshGrpc.Client.Errors`. When `false`, the raw `GRPC.RPCError` is returned."
      ]
    ]
  end
end
