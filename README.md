# Nebulex.Adapters.DiskLFU
> Persistent disk-based cache adapter with LFU eviction for Nebulex.

![CI](https://github.com/elixir-nebulex/nebulex_disk_lfu/workflows/CI/badge.svg)
[![Codecov](https://codecov.io/gh/elixir-nebulex/nebulex_disk_lfu/graph/badge.svg)](https://codecov.io/gh/elixir-nebulex/nebulex_disk_lfu)
[![Hex Version](https://img.shields.io/hexpm/v/nebulex_disk_lfu.svg)](https://hex.pm/packages/nebulex_disk_lfu)
[![Documentation](https://img.shields.io/badge/Documentation-ff69b4)](https://hexdocs.pm/nebulex_disk_lfu)

## About

`Nebulex.Adapters.DiskLFU` is a
**persistent LFU (Least Frequently Used) cache adapter**
for [Nebulex](https://hexdocs.pm/nebulex), designed to provide an SSD-backed
cache with disk persistence, TTL support, and LFU-based eviction.
This adapter is ideal for workloads that require:

- High-capacity caching without exhausting memory.
- File-based persistence with cache recovery after restarts.
- Concurrency-safe operations for both reads and writes.
- Customizable eviction strategies.

## Features

- **LFU Eviction** - Least Frequently Used eviction when disk capacity is
  exceeded.
- **TTL Support** - Per-entry time-to-live with lazy and proactive cleanup.
- **Proactive Eviction** - Automatic periodic cleanup of expired entries via
  `:eviction_timeout`.
- **Manual Cleanup** - Direct API for explicit expired entry removal with
  `delete_all(query: :expired)`.
- **Concurrent Access** - Safe read/write operations with atomic guarantees
  per key.
- **Persistent** - Survives application restarts with fast recovery from disk.

For comprehensive information on architecture, features, and configuration, see the
[Full Documentation](https://hexdocs.pm/nebulex_disk_lfu) and
[Architecture Guide](https://hexdocs.pm/nebulex_disk_lfu/architecture.html).

## Installation

Add `:nebulex_disk_lfu` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nebulex_disk_lfu, "~> 3.0"},
    {:telemetry, "~> 0.4 or ~> 1.0"}  # For observability/telemetry support
  ]
end
```

The `:telemetry` dependency is optional but highly recommended for observability
and monitoring cache operations.

See the [online documentation](https://hexdocs.pm/nebulex_disk_lfu/)
for more information.

## Usage

Define your cache module:

```elixir
defmodule MyApp.Cache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.DiskLFU
end
```

Configure your cache in `config/config.exs`:

```elixir
config :my_app, MyApp.Cache,
  root_path: "/var/cache",
  max_bytes: 10_000_000,               # 10MB capacity
  eviction_timeout: :timer.minutes(5)  # Clean expired entries every 5 minutes
```

Add the cache to your application supervision tree:

```elixir
def start(_type, _args) do
  children = [
    {MyApp.Cache, []},
    # ... other children
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Then use it in your application:

```elixir
# Write a value with TTL
MyApp.Cache.put(:key, "value", ttl: :timer.hours(1))

# Read a value
MyApp.Cache.get(:key)

# Delete expired entries manually
MyApp.Cache.delete_all(query: :expired)
```

For detailed API documentation, configuration options, and more examples, see the
[Adapter Documentation](https://hexdocs.pm/nebulex_disk_lfu/Nebulex.Adapters.DiskLFU.html).

## Benchmarks

Benchmarks were added using [benchee](https://github.com/PragTob/benchee), and
they are located within the directory [benchmarks](./benchmarks).

To run the benchmarks:

```
mix run benchmarks/benchmark.exs
```

## Documentation

- **[Full Adapter Documentation](https://hexdocs.pm/nebulex_disk_lfu/Nebulex.Adapters.DiskLFU.html)** -
  Complete API reference and configuration options.
- **[Architecture Guide](https://hexdocs.pm/nebulex_disk_lfu/architecture.html)** -
  Design, eviction strategy, and concurrency model.
- **[Nebulex Documentation](https://hexdocs.pm/nebulex)** -
  General cache framework documentation.

## Contributing

Contributions to `Nebulex.Adapters.DiskLFU` are very welcome and appreciated!

Use the [issue tracker](https://github.com/elixir-nebulex/nebulex_disk_lfu/issues)
for bug reports or feature requests. Open a
[pull request](https://github.com/elixir-nebulex/nebulex_disk_lfu/pulls)
when you are ready to contribute.

When submitting a pull request you should not update the
[CHANGELOG.md](CHANGELOG.md), and also make sure you test your changes
thoroughly, include unit tests alongside new or changed code.

Before submitting a PR it is highly recommended to run `mix test.ci` and ensure
all checks run successfully.

## Sponsor

- [StanfordTax](https://stanfordtax.com/)

## Copyright and License

Copyright (c) 2025, Carlos Bolaños.

`Nebulex.Adapters.DiskLFU` source code is licensed under the [MIT License](LICENSE).
