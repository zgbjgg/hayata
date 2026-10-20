# Hayata

Hayata is an Erlang/OTP framework for building AI agents around a graph-based execution model.

The project focuses on process isolation, explicit message-based communication, and fault-tolerant execution using OTP primitives.

## Architecture

- **Graph** — coordinates the graph and owns confirmed global state.
- **Node** — a persistent process that owns local state and coordinates outgoing edges.
- **Edge** — a temporary process that runs an edge activation and reports its terminal result.
- **Reducer** — a temporary process that collects edge results for a node execution and produces a consolidated outcome.
- **Executor** — planned component for running individual tasks.

## Project status

Hayata is under active development. The graph, node, edge, and reducer execution flow is being built incrementally, with EUnit tests used to validate behavior.

Current work includes reducer recovery, preserving execution deadlines during recovery, and handling edges that terminate unexpectedly.

## Requirements

- Erlang/OTP 29.1.1 (target runtime)
- Rebar3

## Build and test

Compile:

```sh
rebar3 compile
```

Run tests:

```sh
rebar3 eunit
```

## Design principles

- Use Erlang/OTP processes and monitoring for concurrency and failure detection.
- Keep process responsibilities and state ownership explicit.
- Treat logical IDs separately from process PIDs.
- Build incrementally and validate behavior with tests.

## License

Apache-2.0. See [LICENSE](LICENSE) for details.
