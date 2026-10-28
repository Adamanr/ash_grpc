# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0]

The first release.

### Serving

* `AshGrpc.Resource` and `AshGrpc.Domain` DSL (`grpc do ... end`): messages, fields, field
  tuning, reserved numbers and names, rpcs of every kind (`:get`, `:list`, `:server_stream`,
  `:create`, `:client_stream`, `:update`, `:destroy`, generic actions, `:bidi_stream` with a
  handler), services, packages, file options and imports.
* `use AshGrpc.Endpoint` and `AshGrpc.Server`: generated message and service modules (no
  `protoc`), default handlers calling Ash actions, AIP pagination (keyset and offset tokens),
  update and read masks, `filter`/`order_by`, deadlines as action timeouts, server streaming
  with backpressure, bulk creates over client streams.
* Interceptors: `AshGrpc.Interceptors.Actor` (`AshGrpc.Actor` behaviour),
  `AshGrpc.Interceptors.Tenant` and `AshGrpc.Interceptors.Logger`.
* `grpc.health.v1` health service and server reflection (v1 and v1alpha, optional
  `grpc_reflection` dependency).
* Errors: Ash errors map to gRPC statuses with `google.rpc.BadRequest`, `ErrorInfo` and
  `ResourceInfo` details, extensible through `AshGrpc.ToStatus`. Internal messages are
  hidden unless `show_raised_errors?`.
* Telemetry: `[:ash_grpc, :server, :rpc, :start | :stop | :exception]`.

### Protocol toolkit and codegen

* `AshGrpc.Proto.IR` intermediate representation, plus `Render` (buf `STANDARD`-style `.proto`
  output), `Compiler` (protobuf and gRPC modules with descriptors), `Lock` (stable field
  numbers, automatic reservation of removed fields) and `Diff` (wire-breaking change detection).
* Type mapping for every core Ash type, with presence semantics, `representation:` overrides
  and the `AshGrpc.Type` behaviour; `AshGrpc.Codec` for Ash values ↔ protobuf.
* `mix ash_grpc.codegen` with `--check`, `--dry-run`, `--allow-breaking` and `--buf`; JSON IR
  snapshots as the baseline; the `mix ash.codegen` hook.
* `mix ash_grpc.install` (Igniter).

### Consuming

* `use AshGrpc.Client`: per-service supervised connection pools, name resolution and load
  balancing, TLS/mTLS, deadlines, retries of idempotent rpcs with backoff and jitter, metadata
  (static, function or MFA), compression, message size limits, Ash error mapping, telemetry,
  dynamic clients and `AshGrpc.Client.Sandbox` for tests.
* `AshGrpc.Proto.Import`, `mix ash_grpc.import` and `use AshGrpc.Protos` for foreign `.proto`
  files.
* `AshGrpc.Rpc` generic action implementation.
* `AshGrpc.DataLayer` (`grpc_remote` DSL): resources backed by external gRPC services, with
  filter push-down, page-token pagination, get rpcs, update masks and error mapping.

[Unreleased]: https://github.com/ash-project/ash_grpc/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ash-project/ash_grpc/releases/tag/v0.1.0
