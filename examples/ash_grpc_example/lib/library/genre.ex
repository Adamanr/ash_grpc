defmodule Library.Genre do
  @moduledoc "Genres of books (a protobuf enum: `GENRE_FICTION`, ...)."
  use Ash.Type.Enum, values: [:fiction, :science, :history]
end
