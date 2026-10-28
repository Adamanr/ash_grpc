defmodule AshGrpc.EndpointTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    # every throwaway endpoint redefines the Mini proto modules
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, false) end)
  end

  defp compile(name, opts) do
    Code.compile_string("""
    defmodule #{name} do
      use AshGrpc.Endpoint, #{opts}
    end
    """)
  end

  defp base_opts(lock_path),
    do: ~s(otp_app: :ash_grpc, domains: [AshGrpc.Test.Server.Mini], lock_path: "#{lock_path}")

  test "a missing or stale lock compiles with a warning", %{tmp_dir: dir} do
    lock_path = Path.join(dir, "ash_grpc.lock.json")

    stderr =
      capture_io(:stderr, fn ->
        compile("AshGrpc.EndpointTest.Stale", base_opts(lock_path) <> ", health: false")
      end)

    assert stderr =~ "is missing or out of date"
    stale = Module.concat(["AshGrpc.EndpointTest.Stale"])
    assert %AshGrpc.Proto.IR.Schema{files: [_]} = stale.schema()
    refute AshGrpc.Server.Health.Server in stale.__meta__(:servers)

    # an up-to-date lock compiles silently
    {:ok, _schema, lock} = AshGrpc.Schema.build_with_lock([AshGrpc.Test.Server.Mini])
    AshGrpc.Proto.Lock.write!(lock, lock_path)

    stderr =
      capture_io(:stderr, fn -> compile("AshGrpc.EndpointTest.Fresh", base_opts(lock_path)) end)

    refute stderr =~ "out of date"
  end

  test "require_lock? turns a stale lock into a compile error", %{tmp_dir: dir} do
    lock_path = Path.join(dir, "ash_grpc.lock.json")

    capture_io(:stderr, fn ->
      assert_raise CompileError, ~r/out of date/, fn ->
        compile("AshGrpc.EndpointTest.Required", base_opts(lock_path) <> ", require_lock?: true")
      end
    end)

    Application.put_env(:ash_grpc, :require_lock?, true)

    try do
      capture_io(:stderr, fn ->
        assert_raise CompileError, fn ->
          compile("AshGrpc.EndpointTest.RequiredEnv", base_opts(lock_path))
        end
      end)
    after
      Application.delete_env(:ash_grpc, :require_lock?)
    end
  end

  test "invalid options are compile errors" do
    capture_io(:stderr, fn ->
      assert_raise CompileError, ~r/requires :domains/, fn ->
        compile("AshGrpc.EndpointTest.NoDomains", "otp_app: :ash_grpc")
      end

      assert_raise ArgumentError, fn ->
        compile("AshGrpc.EndpointTest.Unknown", "otp_app: :ash_grpc, nope: 1")
      end
    end)
  end
end
