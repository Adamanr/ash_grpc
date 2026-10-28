defmodule AshGrpc.Domain.Verifiers.VerifyServices do
  @moduledoc """
  Verifies services: names are PascalCase (warns without the `Service` suffix), `rpcs` and
  `resources` refer to rpcs/resources of the domain, rpc names are unique per service and
  resource message names are unique per domain.
  """

  use Spark.Dsl.Verifier

  alias AshGrpc.Domain.{Info, Service}
  alias AshGrpc.Resource.Info, as: ResourceInfo
  alias AshGrpc.Schema.Naming
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    domain = Verifier.get_persisted(dsl_state, :module)
    services = Info.services(domain)
    resources = Info.resources(domain)

    rpcs =
      for resource <- resources, rpc <- ResourceInfo.rpcs(resource) do
        {resource, rpc, Info.service_name(domain, resource, rpc)}
      end

    errors =
      Enum.flat_map(services, &verify_service(domain, &1, resources, rpcs)) ++
        verify_unique_rpcs(domain, rpcs) ++
        verify_unique_messages(domain, resources)

    warnings =
      for service <- services,
          Regex.match?(~r/^[A-Z][A-Za-z0-9]*$/, service.name),
          !String.ends_with?(service.name, "Service") do
        {"#{inspect(domain)}: service #{inspect(service.name)} should end with \"Service\"",
         Spark.Dsl.Entity.anno(service)}
      end

    cond do
      errors != [] -> {:error, errors}
      warnings != [] -> {:warn, warnings}
      true -> :ok
    end
  end

  defp verify_service(domain, %Service{} = service, resources, rpcs) do
    name =
      if Regex.match?(~r/^[A-Z][A-Za-z0-9]*$/, service.name),
        do: [],
        else: [error(domain, service, "service name #{inspect(service.name)} must be PascalCase")]

    unknown_resources =
      for resource <- service.resources, resource not in resources do
        error(
          domain,
          service,
          "#{inspect(resource)} is not a resource of #{inspect(domain)} using AshGrpc.Resource"
        )
      end

    rpc_names = Enum.map(rpcs, fn {_, rpc, _} -> rpc.name end)

    unknown_rpcs =
      for rpc <- service.rpcs, rpc not in rpc_names do
        error(
          domain,
          service,
          "rpc #{inspect(rpc)} is not declared by any resource of #{inspect(domain)}"
        )
      end

    name ++ unknown_resources ++ unknown_rpcs
  end

  defp verify_unique_rpcs(domain, rpcs) do
    rpcs
    |> Enum.group_by(fn {_, rpc, service} -> {service, Naming.rpc_name(rpc.name)} end)
    |> Enum.filter(fn {_, entries} -> length(entries) > 1 end)
    |> Enum.map(fn {{service, name}, entries} ->
      DslError.exception(
        module: domain,
        path: [:grpc, :service, service],
        message:
          "rpc #{name} is declared more than once in service #{service}: " <>
            Enum.map_join(entries, ", ", fn {resource, rpc, _} ->
              "#{inspect(rpc.name)} in #{inspect(resource)}"
            end)
      )
    end)
  end

  defp verify_unique_messages(domain, resources) do
    resources
    |> Enum.group_by(&ResourceInfo.message_name/1)
    |> Enum.filter(fn {_, resources} -> length(resources) > 1 end)
    |> Enum.map(fn {name, resources} ->
      DslError.exception(
        module: domain,
        path: [:grpc],
        message:
          "message name #{inspect(name)} is used by #{inspect(resources)}; set `message` in their grpc sections"
      )
    end)
  end

  defp error(domain, service, message) do
    DslError.exception(
      module: domain,
      path: [:grpc, :service, service.name],
      message: message,
      location: Spark.Dsl.Entity.anno(service)
    )
  end
end
