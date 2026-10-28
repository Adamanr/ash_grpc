defmodule AshGrpc.Schema.Naming do
  @moduledoc """
  Naming conventions used by `AshGrpc.Schema` (buf `STANDARD` lint compatible, DESIGN.md §4.1).
  """

  @doc ~S"""
  The proto rpc name: PascalCase of the DSL name.

      iex> AshGrpc.Schema.Naming.rpc_name(:get_user)
      "GetUser"
  """
  @spec rpc_name(atom() | String.t()) :: String.t()
  def rpc_name(name), do: name |> to_string() |> Macro.camelize()

  @doc ~S"""
  Converts a PascalCase name to lower_snake_case.

      iex> AshGrpc.Schema.Naming.snake("UserProfile")
      "user_profile"
  """
  @spec snake(String.t()) :: String.t()
  def snake(name), do: Macro.underscore(name)

  @doc ~S"""
  Naive English pluralization of a snake_case name.

      iex> AshGrpc.Schema.Naming.pluralize("user")
      "users"

      iex> AshGrpc.Schema.Naming.pluralize("category")
      "categories"

      iex> AshGrpc.Schema.Naming.pluralize("address")
      "addresses"
  """
  @spec pluralize(String.t()) :: String.t()
  def pluralize(name) do
    cond do
      Regex.match?(~r/[^aeiou]y$/, name) -> String.slice(name, 0..-2//1) <> "ies"
      Regex.match?(~r/(s|x|z|ch|sh)$/, name) -> name <> "es"
      true -> name <> "s"
    end
  end
end
