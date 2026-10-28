defmodule AshGrpc.Client.Config do
  @moduledoc """
  Configuration of an `AshGrpc.Client`.

  The configuration of a client is assembled from (later entries win):

    1. the options given to `use AshGrpc.Client`,
    2. `Application.get_env(otp_app, client_module)`,
    3. the options given to `start_link/1` (or the child spec),
    4. the result of the optional `c:AshGrpc.Client.init/1` callback.

  The result is validated against the schema below.

  ## Options

  #{Spark.Options.docs(AshGrpc.Client.Config.Schema.schema())}
  """

  alias AshGrpc.Client.Config.Schema

  @typedoc "A validated client configuration."
  @type t :: %__MODULE__{
          name: atom(),
          module: module() | nil,
          otp_app: atom() | nil,
          services: [module()],
          address: String.t() | nil,
          tls: false | GRPC.Credential.t(),
          pool_size: pos_integer(),
          connect: :eager | :lazy,
          connect_timeout: pos_integer(),
          lb_policy: :round_robin | :pick_first,
          reconnect_attempts: non_neg_integer() | :infinity,
          deadline: pos_integer(),
          retry: false | retry(),
          idempotent: [atom() | String.t()],
          metadata: metadata(),
          compression: nil | module(),
          max_send_message_size: pos_integer() | nil,
          max_receive_message_size: pos_integer() | nil,
          interceptors: [module() | {module(), term()}],
          adapter: module(),
          adapter_opts: keyword(),
          codec: module(),
          sandbox: boolean(),
          map_errors: boolean()
        }

  @typedoc "Retry policy (see the `:retry` option)."
  @type retry :: %{
          max_attempts: pos_integer(),
          backoff: {:exponential, pos_integer(), pos_integer()},
          jitter: boolean(),
          on: [atom()]
        }

  @typedoc "Static or computed metadata (see the `:metadata` option)."
  @type metadata ::
          map()
          | keyword()
          | {module(), atom(), list()}
          | (-> map() | keyword())
          | (map() -> map() | keyword())

  defstruct [
    :name,
    :module,
    :otp_app,
    :address,
    :compression,
    :max_send_message_size,
    :max_receive_message_size,
    services: [],
    tls: false,
    pool_size: 1,
    connect: :eager,
    connect_timeout: 5_000,
    lb_policy: :round_robin,
    reconnect_attempts: :infinity,
    deadline: 10_000,
    retry: false,
    idempotent: [],
    metadata: %{},
    interceptors: [],
    adapter: GRPC.Client.Adapters.Mint,
    adapter_opts: [],
    codec: GRPC.Codec.Proto,
    sandbox: false,
    map_errors: true
  ]

  @doc """
  Builds the configuration for `module` (a `use AshGrpc.Client` module, or `nil` for dynamic
  clients) from the `use` options, application env and start options, then runs the
  `init/1` callback (when defined) and validates the result.
  """
  @spec build(module() | nil, keyword(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def build(module, use_opts, start_opts) do
    otp_app = start_opts[:otp_app] || use_opts[:otp_app]

    env =
      if otp_app && module do
        Application.get_env(otp_app, module, [])
      else
        []
      end

    opts =
      use_opts
      |> Keyword.merge(env)
      |> Keyword.merge(start_opts)
      |> Keyword.put_new(:name, module)

    with {:ok, opts} <- run_init(module, opts),
         {:ok, validated} <- Spark.Options.validate(opts, Schema.schema()) do
      from_validated(module, validated)
    end
  end

  @doc "Same as `build/3`, but raises on invalid configuration."
  @spec build!(module() | nil, keyword(), keyword()) :: t()
  def build!(module, use_opts, start_opts) do
    case build(module, use_opts, start_opts) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  defp run_init(module, opts) do
    if module && Code.ensure_loaded?(module) && function_exported?(module, :init, 1) do
      case module.init(opts) do
        {:ok, opts} when is_list(opts) ->
          {:ok, opts}

        other ->
          {:error,
           ArgumentError.exception(
             "#{inspect(module)}.init/1 must return {:ok, keyword}, got: #{inspect(other)}"
           )}
      end
    else
      {:ok, opts}
    end
  end

  defp from_validated(module, opts) do
    max = opts[:max_message_size]

    config = %__MODULE__{
      name: opts[:name],
      module: module,
      otp_app: opts[:otp_app],
      services: opts[:services],
      address: opts[:address],
      tls: credential(opts[:tls]),
      pool_size: opts[:pool_size],
      connect: opts[:connect],
      connect_timeout: opts[:connect_timeout],
      lb_policy: opts[:lb_policy],
      reconnect_attempts: opts[:reconnect_attempts],
      deadline: opts[:deadline],
      retry: retry(opts[:retry]),
      idempotent: opts[:idempotent],
      metadata: opts[:metadata],
      compression: compressor(opts[:compression]),
      max_send_message_size: opts[:max_send_message_size] || max,
      max_receive_message_size: opts[:max_receive_message_size] || max,
      interceptors: opts[:interceptors],
      adapter: opts[:adapter],
      adapter_opts: opts[:adapter_opts],
      codec: opts[:codec],
      sandbox: opts[:sandbox],
      map_errors: opts[:map_errors]
    }

    cond do
      is_nil(config.name) ->
        {:error, ArgumentError.exception("a client started dynamically requires a :name")}

      is_nil(config.address) and not config.sandbox ->
        {:error,
         ArgumentError.exception("no :address configured for gRPC client #{inspect(config.name)}")}

      true ->
        {:ok, config}
    end
  end

  defp credential(false), do: false
  defp credential(nil), do: false
  defp credential(%GRPC.Credential{} = cred), do: cred

  defp credential(true) do
    GRPC.Credential.new(ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()])
  end

  defp credential(ssl) when is_list(ssl) do
    ssl =
      if Keyword.has_key?(ssl, :cacertfile) or Keyword.has_key?(ssl, :cacerts) do
        ssl
      else
        Keyword.put(ssl, :cacerts, :public_key.cacerts_get())
      end

    GRPC.Credential.new(ssl: Keyword.put_new(ssl, :verify, :verify_peer))
  end

  defp retry(false), do: false
  defp retry(nil), do: false
  defp retry(true), do: retry([])

  defp retry(opts) when is_list(opts) do
    %{
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      backoff: Keyword.get(opts, :backoff, {:exponential, 50, 2_000}),
      jitter: Keyword.get(opts, :jitter, true),
      on: Keyword.get(opts, :on, [:unavailable])
    }
  end

  defp compressor(nil), do: nil
  defp compressor(:gzip), do: GRPC.Compressor.Gzip
  defp compressor(module) when is_atom(module), do: module

  @doc false
  # Spark.Options custom validators.
  def validate_tls(value) when is_boolean(value) or is_nil(value), do: {:ok, value}
  def validate_tls(%GRPC.Credential{} = value), do: {:ok, value}

  def validate_tls(value) when is_list(value) do
    if Keyword.keyword?(value),
      do: {:ok, value},
      else: {:error, "expected :tls to be a keyword list, got: #{inspect(value)}"}
  end

  def validate_tls(value),
    do:
      {:error,
       "expected :tls to be a boolean, ssl keyword list or GRPC.Credential, got: #{inspect(value)}"}

  @doc false
  def validate_metadata(value) when is_map(value), do: {:ok, value}

  def validate_metadata({m, f, a} = value) when is_atom(m) and is_atom(f) and is_list(a),
    do: {:ok, value}

  def validate_metadata(value) when is_function(value, 0) or is_function(value, 1),
    do: {:ok, value}

  def validate_metadata(value) when is_list(value) do
    if Keyword.keyword?(value) or Enum.all?(value, &match?({k, _} when is_binary(k), &1)),
      do: {:ok, value},
      else: {:error, "expected :metadata to be a list of pairs, got: #{inspect(value)}"}
  end

  def validate_metadata(value),
    do:
      {:error,
       "expected :metadata to be a map, keyword list, MFA or function of arity 0 or 1, got: #{inspect(value)}"}

  @doc false
  def validate_retry(value) when is_boolean(value) or is_nil(value), do: {:ok, value}

  def validate_retry(value) when is_list(value) do
    case Spark.Options.validate(value, Schema.retry_schema()) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def validate_retry(value),
    do: {:error, "expected :retry to be false or a keyword list, got: #{inspect(value)}"}

  @doc false
  def validate_backoff({:exponential, base, max} = value)
      when is_integer(base) and base > 0 and is_integer(max) and max >= base,
      do: {:ok, value}

  def validate_backoff(value),
    do:
      {:error, "expected :backoff to be {:exponential, base_ms, max_ms}, got: #{inspect(value)}"}
end
