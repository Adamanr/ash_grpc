# AshGrpc — notes for contributors (and agents)

Read `DESIGN.md` first: it defines the architecture, the IR contract, the module ownership map
and the cross-package function signatures.

* Elixir 1.18 / OTP 27. `protoc` and `buf` are installed locally (`protoc` is only needed for
  importing foreign protos and for tests that validate rendered `.proto` output).
* Main deps: `ash ~> 3.37`, `spark ~> 2.7`, `protobuf ~> 0.17`, `grpc ~> 1.0` (client),
  `grpc_server ~> 1.0`, `googleapis` (google.rpc.*, google.type.*), optional `grpc_reflection`, `igniter`.
  Use Context7 / hexdocs for current APIs — grpc 1.0 split into `grpc`, `grpc_server`, `grpc_core`.
* Commands: `mix test`, `mix check` (format + warnings-as-errors + credo --strict + tests).
* Style: follow Ash ecosystem conventions (look at ash_graphql / ash_json_api for DSL, Info,
  verifiers, transformers; ash_postgres for codegen/snapshots). Spark DSL entities live in
  `lib/ash_grpc/<area>/dsl.ex`-style modules; info modules via `Spark.InfoGenerator`.
* Never use `String.to_atom/1` on wire data. Never leak internal error messages over the wire.
* Test support resources/domains live in `test/support/` (compiled in :test only).
* Commit messages: imperative, scoped (`proto: render oneofs`).
