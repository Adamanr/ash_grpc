defmodule AshGrpc.Proto.Import.Protoc do
  @moduledoc """
  Runs `protoc` to turn `.proto` files into a serialized `FileDescriptorSet`
  (`--include_imports --include_source_info --descriptor_set_out`).
  """

  @doc """
  Returns the encoded descriptor set.

  Options:

    * `:include_paths` – `-I` directories (default: none, `protoc` then uses the
      current directory)
    * `:protoc` – path to the executable (default: `protoc` from `PATH`)
  """
  @spec descriptor_set([Path.t()], Keyword.t()) :: {:ok, binary()} | {:error, term()}
  def descriptor_set(files, opts \\ []) do
    with {:ok, protoc} <- executable(opts) do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ash_grpc_import_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      out = Path.join(tmp_dir, "descriptor_set.pb")

      args =
        Enum.map(Keyword.get(opts, :include_paths, []), &"--proto_path=#{&1}") ++
          ["--include_imports", "--include_source_info", "--descriptor_set_out=#{out}"] ++ files

      try do
        case System.cmd(protoc, args, stderr_to_stdout: true) do
          {_, 0} -> File.read(out)
          {output, status} -> {:error, {:protoc_failed, status, String.trim(output)}}
        end
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  @doc "Locates the `protoc` executable."
  @spec executable(Keyword.t()) :: {:ok, Path.t()} | {:error, term()}
  def executable(opts \\ []) do
    case Keyword.get(opts, :protoc) do
      nil ->
        case System.find_executable("protoc") do
          nil -> {:error, :protoc_not_found}
          path -> {:ok, path}
        end

      path ->
        cond do
          File.regular?(path) -> {:ok, path}
          found = System.find_executable(path) -> {:ok, found}
          true -> {:error, {:protoc_not_found, path}}
        end
    end
  end
end
