defmodule AshGrpc.InterceptorsTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Interceptors.{Actor, Tenant}

  defmodule Parse do
    def tenant("bad", _stream), do: {:error, Ash.Error.Forbidden.exception([])}
    def tenant(value, _stream), do: {:ok, String.to_existing_atom(value)}
  end

  defp stream(headers), do: %GRPC.Server.Stream{http_request_headers: headers}
  defp next, do: fn _request, stream -> stream end

  defp status(fun) do
    error = assert_raise GRPC.RPCError, fun
    AshGrpc.Error.Info.code(error.status)
  end

  describe "Actor" do
    setup do
      %{opts: Actor.init(from: AshGrpc.Test.Server.Auth)}
    end

    test "stores the actor", %{opts: opts} do
      stream = Actor.call(nil, stream(%{"authorization" => "Bearer ada"}), next(), opts)
      assert AshGrpc.Server.actor(stream) == %{id: "ada"}
    end

    test "anonymous requests pass unless required", %{opts: opts} do
      assert AshGrpc.Server.actor(Actor.call(nil, stream(%{}), next(), opts)) == nil

      required = Actor.init(from: AshGrpc.Test.Server.Auth, required?: true)
      assert status(fn -> Actor.call(nil, stream(%{}), next(), required) end) == :unauthenticated
    end

    test "rejected credentials are UNAUTHENTICATED", %{opts: opts} do
      headers = %{"authorization" => "Bearer bad"}
      assert status(fn -> Actor.call(nil, stream(headers), next(), opts) end) == :unauthenticated
    end

    test "requires :from" do
      assert_raise ArgumentError, fn -> Actor.init([]) end
    end
  end

  describe "Tenant" do
    test "reads x-tenant by default" do
      stream = Tenant.call(nil, stream(%{"x-tenant" => "acme"}), next(), Tenant.init([]))
      assert AshGrpc.Server.tenant(stream) == "acme"
      assert AshGrpc.Server.tenant(Tenant.call(nil, stream(%{}), next(), Tenant.init([]))) == nil
    end

    test "custom header, required and parse" do
      opts = Tenant.init(header: "X-Org", required?: true, parse: {Parse, :tenant})

      stream = Tenant.call(nil, stream(%{"x-org" => "ok"}), next(), opts)
      assert AshGrpc.Server.tenant(stream) == :ok

      assert status(fn -> Tenant.call(nil, stream(%{}), next(), opts) end) == :invalid_argument

      assert status(fn -> Tenant.call(nil, stream(%{"x-org" => "bad"}), next(), opts) end) ==
               :permission_denied
    end
  end

  describe "AshGrpc.Server context helpers" do
    test "put_context merges" do
      stream =
        %GRPC.Server.Stream{}
        |> AshGrpc.Server.put_context(%{a: 1})
        |> AshGrpc.Server.put_context(%{b: 2})
        |> AshGrpc.Server.put_actor(:actor)

      assert AshGrpc.Server.context(stream) == %{a: 1, b: 2}
      assert AshGrpc.Server.actor(stream) == :actor
    end
  end
end
