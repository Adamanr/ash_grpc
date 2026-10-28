defmodule Library.Auth do
  @moduledoc """
  Resolves the actor from `authorization: Bearer <name>` metadata. A real service would verify
  a token here (e.g. with AshAuthentication).
  """
  @behaviour AshGrpc.Actor

  @impl true
  def get_actor(metadata, _stream) do
    case metadata["authorization"] do
      nil -> {:ok, nil}
      "Bearer " <> name when name != "" -> {:ok, %{name: name}}
      _ -> {:error, :unauthenticated}
    end
  end
end
