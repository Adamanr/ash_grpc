defmodule AshGrpc.Test.DslHelpers do
  @moduledoc false
  # Helpers for verifier tests: collect DslError messages produced while defining modules.

  defmacro dsl_error_messages(do: block) do
    quote do
      require Spark.Test

      Spark.Test.dsl_errors do
        unquote(block)
      end
      |> Enum.flat_map(fn {_module, errors} -> errors end)
      |> Enum.map(&Exception.message/1)
    end
  end

  defmacro dsl_warning_messages(do: block) do
    quote do
      require Spark.Test

      Spark.Test.dsl_warnings do
        unquote(block)
      end
      |> Enum.flat_map(fn {_module, warnings} -> warnings end)
      |> Enum.map(fn {message, _location} -> message end)
    end
  end
end
