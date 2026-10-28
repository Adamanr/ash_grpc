defmodule AshGrpc.Domain.Verifiers.VerifyPackage do
  @moduledoc """
  Verifies the package (`lower.snake` segments; warns when unversioned) and the file path.
  """

  use Spark.Dsl.Verifier

  alias AshGrpc.Domain.Info
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    domain = Verifier.get_persisted(dsl_state, :module)
    package = Info.package(domain)
    file = Info.file(domain)
    package_anno = Spark.Dsl.Extension.get_opt_anno(dsl_state, [:grpc], :package)
    file_anno = Spark.Dsl.Extension.get_opt_anno(dsl_state, [:grpc], :file)

    errors =
      Enum.reject(
        [
          !Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/, package) &&
            error(
              domain,
              :package,
              "package #{inspect(package)} must be dot-separated lower_snake_case segments, e.g. \"myapp.accounts.v1\"",
              package_anno
            ),
          (!String.ends_with?(file, ".proto") or String.starts_with?(file, "/") or
             ".." in Path.split(file)) &&
            error(
              domain,
              :file,
              "file #{inspect(file)} must be a relative path ending in .proto",
              file_anno
            )
        ],
        &(&1 == false)
      )

    cond do
      errors != [] ->
        {:error, errors}

      Info.versioned_package?(package) ->
        :ok

      true ->
        {:warn,
         {"#{inspect(domain)}: package #{inspect(package)} is not versioned. " <>
            "Use a version suffix such as \"#{package}.v1\" so breaking changes can get a new package.",
          package_anno}}
    end
  end

  defp error(domain, option, message, anno) do
    DslError.exception(module: domain, path: [:grpc, option], message: message, location: anno)
  end
end
