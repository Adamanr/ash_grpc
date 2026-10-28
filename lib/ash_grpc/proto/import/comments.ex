defmodule AshGrpc.Proto.Import.Comments do
  @moduledoc """
  Extracts docs from a `FileDescriptorProto`'s `source_code_info`.

  Only comments attached to a declaration (leading and trailing) become docs;
  detached comments are ignored. Paths follow `descriptor.proto` numbering, e.g.
  `[4, 0, 2, 1]` is the second field of the first top-level message.
  """

  @type t :: %{optional([non_neg_integer()]) => String.t()}

  @doc "Builds a map of `path => doc`."
  @spec index(Google.Protobuf.FileDescriptorProto.t()) :: t()
  def index(%{source_code_info: %{location: locations}}) when is_list(locations) do
    Enum.reduce(locations, %{}, fn location, acc ->
      case doc(location) do
        nil -> acc
        doc -> Map.put_new(acc, List.wrap(location.path), doc)
      end
    end)
  end

  def index(_file), do: %{}

  @doc "Doc for a path, or `nil`."
  @spec get(t(), [non_neg_integer()]) :: String.t() | nil
  def get(index, path), do: Map.get(index, path)

  defp doc(location) do
    [location.leading_comments, location.trailing_comments]
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp normalize(nil), do: nil

  defp normalize(comment) do
    lines = comment |> String.trim_trailing() |> String.split("\n")

    indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line -> String.length(line) - String.length(String.trim_leading(line)) end)
      |> Enum.min(fn -> 0 end)

    lines
    |> Enum.map_join("\n", &(&1 |> String.slice(indent..-1//1) |> String.trim_trailing()))
    |> String.trim()
  end
end
