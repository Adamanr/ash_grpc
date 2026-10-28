defmodule AshGrpc.Domain.Info do
  @moduledoc """
  Introspection for `AshGrpc.Domain`.

  Besides the generated `grpc_*` accessors, it provides the resolved values (`package/1`,
  `file/1`, `module_prefix/1`, `service_name/3`, ...) with defaults applied.
  """

  use Spark.InfoGenerator, extension: AshGrpc.Domain, sections: [:grpc]

  alias AshGrpc.Domain.{Option, Service}
  alias AshGrpc.Resource.Rpc

  @version ~r/^v\d+((alpha|beta)\d*)?$/

  @doc "Returns true if the domain uses the `AshGrpc.Domain` extension."
  @spec grpc?(module()) :: boolean()
  def grpc?(domain) do
    is_atom(domain) and Code.ensure_loaded?(domain) and
      function_exported?(domain, :spark_dsl_config, 0) and
      AshGrpc.Domain in Spark.extensions(domain)
  end

  @doc "The proto package (default: underscored module name, e.g. `my_app.accounts`)."
  @spec package(module()) :: String.t()
  def package(domain) do
    case grpc_package(domain) do
      {:ok, package} -> package
      :error -> domain |> Module.split() |> Enum.map_join(".", &Macro.underscore/1)
    end
  end

  @doc "True if the last package segment is a version (`v1`, `v2beta1`, ...)."
  @spec versioned_package?(String.t()) :: boolean()
  def versioned_package?(package),
    do: Regex.match?(@version, package |> String.split(".") |> List.last())

  @doc "The `.proto` import path of the domain file."
  @spec file(module()) :: String.t()
  def file(domain) do
    case grpc_file(domain) do
      {:ok, file} ->
        file

      :error ->
        package = package(domain)
        segments = String.split(package, ".")
        Path.join(segments ++ ["#{base_name(package)}.proto"])
    end
  end

  @doc "The Elixir module prefix for generated modules."
  @spec module_prefix(module()) :: module()
  def module_prefix(domain) do
    case grpc_module_prefix(domain) do
      {:ok, prefix} -> prefix
      :error -> package_module(package(domain))
    end
  end

  @doc "Camelizes a package into a module (`myapp.accounts.v1` → `Myapp.Accounts.V1`)."
  @spec package_module(String.t()) :: module()
  def package_module(package),
    do: package |> String.split(".") |> Enum.map(&Macro.camelize/1) |> Module.concat()

  @doc "The file options as `{name, value}` pairs."
  @spec options(module()) :: [{atom() | String.t(), term()}]
  def options(domain) do
    for %Option{name: name, value: value} <- grpc(domain), do: {name, value}
  end

  @doc "The declared `service` entities."
  @spec services(module()) :: [Service.t()]
  def services(domain), do: Enum.filter(grpc(domain), &is_struct(&1, Service))

  @doc "The resources of the domain that use `AshGrpc.Resource`."
  @spec resources(module()) :: [module()]
  def resources(domain),
    do: domain |> Ash.Domain.Info.resources() |> Enum.filter(&AshGrpc.Resource.Info.grpc?/1)

  @doc "The service name used when no declared service applies."
  @spec default_service_name(module()) :: String.t()
  def default_service_name(domain) do
    case Enum.find(services(domain), &Service.default?/1) do
      %Service{name: name} -> name
      nil -> Macro.camelize(base_name(package(domain))) <> "Service"
    end
  end

  @doc "The name of the service an rpc of a resource belongs to."
  @spec service_name(module(), module(), Rpc.t()) :: String.t()
  def service_name(domain, resource, %Rpc{} = rpc) do
    services = services(domain)

    cond do
      rpc.service -> rpc.service
      service = Enum.find(services, &(rpc.name in &1.rpcs)) -> service.name
      service = Enum.find(services, &(resource in &1.resources)) -> service.name
      true -> default_service_name(domain)
    end
  end

  # Last package segment that is not a version: `myapp.accounts.v1` → `accounts`.
  defp base_name(package) do
    package
    |> String.split(".")
    |> Enum.reject(&Regex.match?(@version, &1))
    |> List.last()
    |> Kernel.||("api")
  end
end
