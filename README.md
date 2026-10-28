# AshGrpc

gRPC for the [Ash Framework](https://ash-hq.org).

* Expose Ash actions as gRPC services with a `grpc do ... end` DSL
* Generate `.proto` files to share with other teams — with stable field numbers and a breaking-change check
* Connect to any number of external gRPC services (`use AshGrpc.Client`)
* Import foreign `.proto` files and use them from Ash (generic actions or a remote data layer)

> Status: early development. See [DESIGN.md](DESIGN.md) for the architecture and the work plan.

## Installation

```elixir
def deps do
  [{:ash_grpc, "~> 0.1"}]
end
```
