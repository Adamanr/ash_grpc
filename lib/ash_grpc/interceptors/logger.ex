defmodule AshGrpc.Interceptors.Logger do
  @moduledoc """
  Server interceptor that logs every rpc with its status and duration:

      [info] GRPC /myapp.accounts.v1.AccountsService/GetUser -> OK in 1.2ms

  ## Options

    * `:level` – log level for successful calls (default `:info`)
    * `:error_level` – log level for failed calls (default `:warning`)
  """

  @behaviour GRPC.Server.Interceptor

  require Logger

  @impl true
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: Keyword.validate!(opts, level: :info, error_level: :warning)

  @impl true
  def call(request, stream, next, opts) do
    start = System.monotonic_time()
    path = "/#{stream.service_name}/#{stream.method_name}"

    try do
      result = next.(request, stream)
      log(opts[:level], path, "OK", start)
      result
    rescue
      error in GRPC.RPCError ->
        log(opts[:error_level], path, status_name(error.status), start)
        reraise error, __STACKTRACE__
    end
  end

  defp log(level, path, status, start) do
    Logger.log(level, fn ->
      duration = System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)
      "GRPC #{path} -> #{status} in #{format_duration(duration)}"
    end)
  end

  defp format_duration(us) when us < 1_000, do: "#{us}µs"
  defp format_duration(us), do: "#{Float.round(us / 1_000, 1)}ms"

  defp status_name(status) when is_integer(status),
    do: status |> AshGrpc.Error.Info.code() |> Atom.to_string() |> String.upcase()

  defp status_name(status), do: inspect(status)
end
