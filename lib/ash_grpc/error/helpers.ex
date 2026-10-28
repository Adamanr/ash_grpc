defmodule AshGrpc.Error.Helpers do
  @moduledoc false
  # Helpers for `AshGrpc.ToStatus` implementations.

  alias AshGrpc.Type.Naming

  @doc "The message of an error, never raising."
  @spec message(term()) :: String.t()
  def message(%{message: message, vars: vars}) when is_binary(message) and message != "",
    do: interpolate(message, vars)

  def message(%{message: message}) when is_binary(message) and message != "", do: message

  def message(error) when is_exception(error) do
    Exception.message(error)
  rescue
    _ -> inspect(error.__struct__)
  end

  def message(error), do: inspect(error)

  @doc "The short description of an invalid value (`message` field with vars), or the default."
  @spec description(term(), String.t()) :: String.t()
  def description(%{message: message} = error, _default)
      when is_binary(message) and message != "",
      do: interpolate(message, Map.get(error, :vars, []))

  def description(_error, default), do: default

  @doc "Replaces `%{key}` placeholders with `vars`."
  @spec interpolate(String.t(), Keyword.t() | map()) :: String.t()
  def interpolate(message, vars) do
    Enum.reduce(vars || [], message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", var_to_string(value))
    end)
  end

  @doc "Field path of an error (`path ++ [field]`)."
  @spec path(term(), atom() | String.t() | nil) :: [atom() | String.t() | integer()]
  def path(error, field) do
    List.wrap(Map.get(error, :path)) ++ List.wrap(field)
  end

  @doc "`ErrorInfo.reason` derived from the error module (`InvalidAttribute` → `INVALID_ATTRIBUTE`)."
  @spec reason(term()) :: String.t()
  def reason(%module{}), do: module |> Naming.module_short_name() |> Naming.constant()
  def reason(_), do: "UNKNOWN"

  @doc "Short (proto-style) name of a resource module."
  @spec resource_name(module() | nil) :: String.t() | nil
  def resource_name(nil), do: nil
  def resource_name(resource) when is_atom(resource), do: Naming.module_short_name(resource)
  def resource_name(_), do: nil

  defp var_to_string(value) when is_binary(value), do: value

  defp var_to_string(value) when is_atom(value) or is_number(value),
    do: to_string(value)

  defp var_to_string(value) when is_list(value) do
    if List.ascii_printable?(value),
      do: to_string(value),
      else: Enum.map_join(value, ", ", &var_to_string/1)
  end

  defp var_to_string(value), do: inspect(value)
end
