defmodule AshGrpc.Domain do
  @option %Spark.Dsl.Entity{
    name: :option,
    target: AshGrpc.Domain.Option,
    args: [:name, :value],
    identifier: :name,
    describe: "A file-level proto option.",
    examples: [
      ~s(option :go_package, "github.com/acme/myapp/gen/accounts/v1;accountsv1"),
      "option :java_multiple_files, true"
    ],
    schema: AshGrpc.Domain.Option.schema()
  }

  @service %Spark.Dsl.Entity{
    name: :service,
    target: AshGrpc.Domain.Service,
    args: [:name],
    identifier: :name,
    no_depend_modules: [:resources],
    describe: """
    Declares a service. A service without `rpcs` and `resources` is the default service of the
    domain; others group specific rpcs or resources. See `AshGrpc.Domain.Service` for how rpcs
    are assigned.
    """,
    examples: [
      ~s(service "AccountsService"),
      ~s(service "AdminService", rpcs: [:ban_user], doc: "Back-office operations"),
      ~s(service "PostsService", resources: [MyApp.Accounts.Post])
    ],
    schema: AshGrpc.Domain.Service.schema()
  }

  @grpc %Spark.Dsl.Section{
    name: :grpc,
    describe: "Configures the `.proto` file and services generated for the domain.",
    examples: [
      """
      grpc do
        package "myapp.accounts.v1"
        file "myapp/accounts/v1/accounts.proto"
        module_prefix MyApp.Grpc.Accounts.V1

        option :go_package, "github.com/acme/myapp/gen/accounts/v1;accountsv1"

        service "AccountsService"
        service "AdminService", rpcs: [:ban_user]
      end
      """
    ],
    no_depend_modules: [:module_prefix],
    schema: [
      package: [
        type: :string,
        doc: """
        The proto package (`lower.snake.v1`). Defaults to the underscored module name
        (`MyApp.Accounts` → `my_app.accounts`); unversioned packages produce a warning.
        """
      ],
      file: [
        type: :string,
        doc: """
        The `.proto` import path. Defaults to the package path plus the last unversioned
        package segment (`myapp.accounts.v1` → `myapp/accounts/v1/accounts.proto`).
        """
      ],
      module_prefix: [
        type: :atom,
        doc:
          "Prefix for the Elixir modules of messages/enums/services. Defaults to the camelized package (`Myapp.Accounts.V1`)."
      ],
      doc: [type: :string, doc: "File comment."],
      imports: [
        type: {:list, :string},
        default: [],
        doc: "Extra import paths, e.g. for external `request_message`/`response_message` modules."
      ]
    ],
    entities: [@option, @service]
  }

  @sections [@grpc]

  @moduledoc """
  Spark extension that turns an Ash domain into a `.proto` file with gRPC services.

  ```elixir
  use Ash.Domain, extensions: [AshGrpc.Domain]
  ```

  Every resource of the domain that uses `AshGrpc.Resource` contributes its message and rpcs.
  See the generated DSL documentation for all options.

  `mix ash.codegen` also runs `mix ash_grpc.codegen` through this extension (`codegen/1`).
  """

  use Spark.Dsl.Extension,
    sections: @sections,
    verifiers: [
      AshGrpc.Domain.Verifiers.VerifyPackage,
      AshGrpc.Domain.Verifiers.VerifyServices
    ]

  @behaviour Ash.Extension

  @doc """
  Ash extension codegen hook: `mix ash.codegen [name]` (and `--check`, `--dry-run`) runs
  `mix ash_grpc.codegen` with the same arguments.
  """
  @impl Ash.Extension
  def codegen(argv) do
    Mix.Task.reenable("ash_grpc.codegen")
    Mix.Task.run("ash_grpc.codegen", Enum.filter(argv, &is_binary/1))
  end
end
