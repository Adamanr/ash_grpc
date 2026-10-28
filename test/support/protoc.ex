defmodule AshGrpc.Test.Protoc do
  @moduledoc """
  Helpers to run the real `protoc` / `buf` binaries in tests.

  Test modules that need them should be tagged `:protoc` and skip themselves
  when `available?/0` is false.
  """

  alias AshGrpc.Proto.Render
  alias AshGrpc.Test.ProtoFixtures

  @doc "Whether `protoc` is on the PATH."
  def available?, do: System.find_executable("protoc") != nil

  @doc "Whether `buf` is on the PATH."
  def buf_available?, do: System.find_executable("buf") != nil

  @doc """
  Renders IR files into `dir` (plus the hand-written fixture protos) and
  returns the paths of the rendered files.
  """
  def write_files!(files, dir, render_opts \\ []) do
    File.cp_r!(ProtoFixtures.protos_dir(), dir)

    Enum.map(files, fn file ->
      path = Path.join(dir, file.path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Render.render(file, render_opts))
      file.path
    end)
  end

  @doc """
  Runs `protoc` over the given relative paths in `dir` and returns the decoded
  `Google.Protobuf.FileDescriptorSet` (with imports). Raises with protoc's output on failure.
  """
  def descriptor_set!(dir, paths) do
    out = Path.join(dir, "descriptor_set.pb")

    case System.cmd(
           "protoc",
           ["-I", dir, "--include_imports", "--descriptor_set_out=#{out}" | paths],
           stderr_to_stdout: true
         ) do
      {_, 0} -> out |> File.read!() |> Google.Protobuf.FileDescriptorSet.decode()
      {output, status} -> raise "protoc failed (#{status}):\n#{output}"
    end
  end

  @doc "Runs `buf format -d` in `dir`; returns the diff output (empty when formatted)."
  def buf_format_diff(dir) do
    {output, _status} = System.cmd("buf", ["format", "-d", dir], stderr_to_stdout: true)
    output
  end

  @doc """
  Generates Elixir source for `file_name` with the real protoc-gen-elixir
  generator (in-process, from a descriptor set produced by protoc), with
  `gen_descriptors=true` and the grpc plugin. `package_prefix` keeps the
  generated modules apart from the ones compiled by AshGrpc.
  """
  def generate_elixir!(%Google.Protobuf.FileDescriptorSet{file: descs}, file_name, package_prefix) do
    ctx =
      %Protobuf.Protoc.Context{}
      |> Protobuf.Protoc.CLI.parse_params(
        "plugins=grpc,gen_descriptors=true,package_prefix=#{package_prefix}"
      )
      |> Protobuf.Protoc.CLI.find_types(descs, [file_name])

    desc = Enum.find(descs, &(&1.name == file_name))
    {_extensions, files} = Protobuf.Protoc.Generator.generate(ctx, desc)
    Enum.map_join(files, "\n", & &1.content)
  end
end
