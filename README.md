# Nebulex.Adapters.DiskLFU
> A Nebulex adapter for a disk-based LFU cache.

![CI](http://github.com/elixir-nebulex/nebulex_disk_lfu/workflows/CI/badge.svg)
[![Codecov](http://codecov.io/gh/elixir-nebulex/nebulex_disk_lfu/graph/badge.svg)](http://codecov.io/gh/elixir-nebulex/nebulex_disk_lfu/graph/badge.svg)
[![Hex Version](http://img.shields.io/hexpm/v/nebulex_disk_lfu.svg)](http://hex.pm/packages/nebulex_disk_lfu)
[![Documentation](http://img.shields.io/badge/Documentation-ff69b4)](http://hexdocs.pm/nebulex_disk_lfu)

## About

This adapter is ideally for those use cases when you want to use a disk-based
cache storage to optimize expensive operations. For example, you have an
application that downloads large files from S3 to process them, and those
files are reusable. In such cases, it may be cheaper reading the file from
the local file system (ideally using SSD) rather that reading it multiple
times from S3.

This adapter stores the cache in a directory on the file system. It uses the
[LFU](https://en.wikipedia.org/wiki/Least_Frequently_Used) algorithm to
evict the least frequently used items.

---
> [!NOTE]
>
> _**Still under development!**_
>
> `Nebulex.Adapters.DiskLFU` is only compatible with Nebulex v3.0.0 or later.
---

## Installation

Add `:nebulex_disk_lfu` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nebulex_disk_lfu, "~> 0.1"}
  ]
end
```

See the [online documentation](http://hexdocs.pm/nebulex_disk_lfu/)
for more information.

## Usage

You can define a cache using as follows:

```elixir
defmodule MyApp.Cache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.DiskLFU
end
```

Where the configuration for the cache must be in your application
environment, usually defined in your `config/config.exs`:

```elixir
config :my_app, MyApp.Cache,
  base_dir: "/var/cache",
  ...
```

## Benchmarks

Benchmarks were added using [benchee](http://github.com/PragTob/benchee), and
they are located within the directory [benchmarks](./benchmarks).

To run the benchmarks:

```
mix run benchmarks/benchmark.exs
```

## Contributing

Contributions to Nebulex are very welcome and appreciated!

Use the [issue tracker](http://github.com/elixir-nebulex/nebulex_disk_lfu/issues)
for bug reports or feature requests. Open a
[pull request](http://github.com/elixir-nebulex/nebulex_disk_lfu/pulls)
when you are ready to contribute.

When submitting a pull request you should not update the
[CHANGELOG.md](CHANGELOG.md), and also make sure you test your changes
thoroughly, include unit tests alongside new or changed code.

Before to submit a PR it is highly recommended to run `mix test.ci` and ensure
all checks run successfully.

## Sponsor

- [StanfordTax](http://stanfordtax.com/)

## Copyright and License

Copyright (c) 2025, Carlos Bolaños.

`Nebulex.Adapters.DiskLFU` source code is licensed under the [MIT License](LICENSE).
