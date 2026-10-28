defmodule AshGrpc.Type.Naming do
  @moduledoc """
  Naming helpers shared by `AshGrpc.Type.Mapping` and `AshGrpc.Codec`.

  The codec relies on these functions being deterministic: an enum value name
  is always `enum_prefix(enum_name) <> "_" <> constant(value)`, so values can be
  matched without generating atoms from wire data.
  """

  @doc """
  Converts a term to `UPPER_SNAKE_CASE` (proto enum constants).

      iex> AshGrpc.Type.Naming.constant(:super_admin)
      "SUPER_ADMIN"
      iex> AshGrpc.Type.Naming.constant("fooBar-baz")
      "FOO_BAR_BAZ"
  """
  @spec constant(atom() | String.t()) :: String.t()
  def constant(value), do: value |> snake() |> String.upcase()

  @doc """
  Converts a term to `lower_snake_case` (proto field names).

      iex> AshGrpc.Type.Naming.snake(:"Some Field")
      "some_field"
  """
  @spec snake(atom() | String.t()) :: String.t()
  def snake(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    |> Macro.underscore()
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end

  @doc """
  Converts a term to `PascalCase` (proto message/enum names).

      iex> AshGrpc.Type.Naming.pascal(:shipping_address)
      "ShippingAddress"
  """
  @spec pascal(atom() | String.t()) :: String.t()
  def pascal(value), do: value |> snake() |> Macro.camelize()

  @doc """
  The prefix of the values of an enum, derived from its (short or full) name.

      iex> AshGrpc.Type.Naming.enum_prefix("myapp.v1.UserRole")
      "USER_ROLE"
  """
  @spec enum_prefix(String.t()) :: String.t()
  def enum_prefix(enum_name) do
    enum_name |> String.split(".") |> List.last() |> constant()
  end

  @doc "Name of the enum value representing `value`."
  @spec enum_value_name(String.t(), atom() | String.t()) :: String.t()
  def enum_value_name(enum_name, value), do: enum_prefix(enum_name) <> "_" <> constant(value)

  @doc "Name of the `*_UNSPECIFIED = 0` value of an enum."
  @spec unspecified_name(String.t()) :: String.t()
  def unspecified_name(enum_name), do: enum_prefix(enum_name) <> "_UNSPECIFIED"

  @doc "Short (last segment) name of a module."
  @spec module_short_name(module()) :: String.t()
  def module_short_name(module), do: module |> Module.split() |> List.last()
end
