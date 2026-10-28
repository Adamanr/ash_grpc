defmodule AshGrpc.Client.Retry do
  @moduledoc """
  Retry policy of client calls.

  A failed attempt is retried only when all of the following hold:

    * the client (or the call, via `retry:`) has a retry policy,
    * the rpc is idempotent: declared so by the service descriptor (`idempotency_level`
      `NO_SIDE_EFFECTS` or `IDEMPOTENT`), listed in the client's `:idempotent` option, or the
      call passes `idempotent: true`,
    * the status is in the policy's `:on` list (`[:unavailable]` by default),
    * attempts are left (`:max_attempts` counts the first attempt) and the backoff delay still
      fits into the call's deadline (the deadline covers all attempts).

  The delay before attempt `n + 1` is `min(max, base * 2^(n - 1))` ms with "full jitter"
  (uniformly random between 0 and that value) unless `jitter: false`.
  """

  alias AshGrpc.Client.Errors

  @typedoc "A normalized retry policy (see `AshGrpc.Client.Config`)."
  @type policy :: false | AshGrpc.Client.Config.retry()

  @doc "Runs `fun` (receiving the attempt number) under `policy`. Returns `{result, attempts}`."
  @spec run(policy(), boolean(), integer(), (pos_integer() -> result)) ::
          {result, pos_integer()}
        when result: term()
  def run(policy, idempotent?, deadline_at, fun) do
    do_run(policy, idempotent?, deadline_at, fun, 1)
  end

  defp do_run(policy, idempotent?, deadline_at, fun, attempt) do
    result = fun.(attempt)

    with {:error, %GRPC.RPCError{status: status}} <- result,
         true <- retry?(policy, idempotent?, status, attempt),
         delay = delay(policy, attempt),
         true <- now() + delay < deadline_at do
      Process.sleep(delay)
      do_run(policy, idempotent?, deadline_at, fun, attempt + 1)
    else
      _ -> {result, attempt}
    end
  end

  @doc "Whether an attempt that failed with `status` may be retried."
  @spec retry?(policy(), boolean(), non_neg_integer(), pos_integer()) :: boolean()
  def retry?(false, _idempotent?, _status, _attempt), do: false
  def retry?(_policy, false, _status, _attempt), do: false

  def retry?(%{max_attempts: max, on: on}, true, status, attempt) do
    attempt < max and Errors.status_name(status) in on
  end

  @doc "Backoff delay in ms after the given (failed) attempt."
  @spec delay(AshGrpc.Client.Config.retry(), pos_integer()) :: non_neg_integer()
  def delay(%{backoff: {:exponential, base, max}} = policy, attempt) do
    delay = min(max, base * Integer.pow(2, attempt - 1))
    if Map.get(policy, :jitter, true), do: :rand.uniform(delay + 1) - 1, else: delay
  end

  @doc """
  Merges a per-call `retry:` option into the client policy (`false` disables retries,
  a keyword list overrides individual keys).
  """
  @spec merge(policy(), false | nil | keyword()) :: policy()
  def merge(policy, nil), do: policy
  def merge(_policy, false), do: false

  def merge(policy, overrides) when is_list(overrides) do
    base =
      policy ||
        %{max_attempts: 3, backoff: {:exponential, 50, 2_000}, jitter: true, on: [:unavailable]}

    Map.merge(base, Map.new(overrides))
  end

  defp now, do: System.monotonic_time(:millisecond)
end
