defmodule AshGrpc.Server.Pagination do
  @moduledoc """
  Pagination of `:list` rpcs (AIP-158).

  `page_size` defaults to the endpoint's `default_page_size` (or the action's `default_limit`)
  and is capped by the endpoint's `max_page_size` and the action's `max_page_size`.
  `page_token` / `next_page_token` are opaque URL-safe base64 tokens:

    * actions with keyset pagination only use Ash keysets (stable under concurrent inserts),
    * actions with offset pagination (including the default `read` action, which supports
      both) and actions without pagination use offsets.

  `total_size` is returned when the action's pagination is countable.
  """

  alias AshGrpc.Server.{Context, Masks}

  @doc """
  Reads one page: `{records, next_page_token, total_size | nil}`.
  """
  @spec read(Ash.Query.t(), struct(), Context.t()) :: {[struct()], String.t(), integer() | nil}
  def read(query, request, %Context{} = ctx) do
    pagination = ctx.action.pagination || nil
    size = page_size(Map.get(request, :page_size) || 0, pagination, ctx.settings)
    token = decode_token(Map.get(request, :page_token))
    opts = Context.call_opts(ctx)

    # Ash serves offset pages when an action supports both and no keyset is given
    cond do
      pagination && pagination.offset? ->
        offset_page(query, size, token, pagination, opts)

      pagination && pagination.keyset? ->
        keyset_page(query, size, token, pagination, opts)

      true ->
        manual_page(query, size, token, opts)
    end
  end

  defp keyset_page(query, size, token, pagination, opts) do
    after_keyset =
      case token do
        nil -> []
        {:keyset, keyset} -> [after: keyset]
        _ -> invalid_token!()
      end

    page = [limit: size, count: countable?(pagination)] ++ after_keyset

    case Ash.read(query, Keyword.put(opts, :page, page)) do
      {:ok, %Ash.Page.Keyset{} = result} ->
        next =
          if result.more? and result.results != [] do
            encode_token({:keyset, List.last(result.results).__metadata__.keyset})
          else
            ""
          end

        {result.results, next, result.count}

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
  end

  defp offset_page(query, size, token, pagination, opts) do
    offset = offset(token)
    page = [limit: size, offset: offset, count: countable?(pagination)]

    case Ash.read(query, Keyword.put(opts, :page, page)) do
      {:ok, %Ash.Page.Offset{} = result} ->
        next =
          if result.more?, do: encode_token({:offset, offset + length(result.results)}), else: ""

        {result.results, next, result.count}

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
  end

  defp manual_page(query, size, token, opts) do
    offset = offset(token)

    query
    |> Ash.Query.limit(size + 1)
    |> Ash.Query.offset(offset)
    |> Ash.read(opts)
    |> case do
      {:ok, records} ->
        {page, rest} = Enum.split(records, size)
        next = if rest == [], do: "", else: encode_token({:offset, offset + size})
        {page, next, nil}

      {:error, error} ->
        raise Ash.Error.to_error_class(error)
    end
  end

  defp offset(nil), do: 0
  defp offset({:offset, offset}), do: offset
  defp offset(_), do: invalid_token!()

  defp countable?(%{countable: countable}), do: countable in [true, :by_default]

  @doc false
  @spec page_size(integer(), struct() | nil, map()) :: pos_integer()
  def page_size(requested, pagination, settings) do
    if requested < 0, do: Masks.invalid!("page_size", "must not be negative")

    default = settings.default_page_size || (pagination && pagination.default_limit) || 50

    max =
      Enum.min([
        settings.max_page_size || 1_000,
        (pagination && pagination.max_page_size) || 1_000
      ])

    requested |> then(&if(&1 == 0, do: default, else: &1)) |> min(max) |> max(1)
  end

  @doc "Encodes a page token."
  @spec encode_token({:keyset, String.t()} | {:offset, non_neg_integer()}) :: String.t()
  def encode_token({:keyset, keyset}), do: Base.url_encode64("k:" <> keyset, padding: false)

  def encode_token({:offset, offset}),
    do: Base.url_encode64("o:" <> Integer.to_string(offset), padding: false)

  @doc "Decodes a page token (`nil` for an empty token); raises `INVALID_ARGUMENT` on garbage."
  @spec decode_token(String.t() | nil) ::
          nil | {:keyset, String.t()} | {:offset, non_neg_integer()}
  def decode_token(blank) when blank in [nil, ""], do: nil

  def decode_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, "k:" <> keyset} when keyset != "" ->
        {:keyset, keyset}

      {:ok, "o:" <> offset} ->
        case Integer.parse(offset) do
          {offset, ""} when offset >= 0 -> {:offset, offset}
          _ -> invalid_token!()
        end

      _ ->
        invalid_token!()
    end
  end

  defp invalid_token!, do: Masks.invalid!("page_token", "invalid page token")
end
