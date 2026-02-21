# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v3.0.0](https://github.com/elixir-nebulex/nebulex_disk_lfu/tree/v3.0.0) (2026-02-21)
> [Full Changelog](https://github.com/elixir-nebulex/nebulex_disk_lfu/compare/v3.0.0-rc.1...v3.0.0)

### Enhancements

- [Nebulex.Adapters.DiskLFU] Replaced the previous default transaction
  implementation from `Nebulex.Adapter.Transaction` with an adapter-owned
  `:global`-based implementation. Transaction lock IDs now use a dedicated
  transaction namespace to avoid interference with internal store locks while
  preserving nested transaction behavior.

## [v3.0.0-rc.1](https://github.com/elixir-nebulex/nebulex_disk_lfu/tree/v3.0.0-rc.1) (2025-06-22)
> [Full Changelog](https://github.com/elixir-nebulex/nebulex_disk_lfu/compare/2c6188ebb9a482cd75a97b6abdb2feddcfb189c9...v3.0.0-rc.1)

### Enhancements

- [Nebulex.Adapters.DiskLFU] Initial release of persistent LFU cache adapter
  for Nebulex v3.
- [Nebulex.Adapters.DiskLFU] Disk-based cache with SHA256-hashed file storage
  (`.cache` and `.meta` files).
- [Nebulex.Adapters.DiskLFU] LFU (Least Frequently Used) eviction strategy
  with configurable size limits (`:max_bytes`).
- [Nebulex.Adapters.DiskLFU] TTL support with lazy expiration (on access),
  eager eviction (prioritizes expired entries), and optional periodic cleanup
  (`:eviction_timeout`).
- [Nebulex.Adapters.DiskLFU] Atomic operations using `:global.trans/4` for
  per-key and cache-wide locking.
- [Nebulex.Adapters.DiskLFU] ETS-based metadata caching with `:counters` for
  fast size tracking.
- [Nebulex.Adapters.DiskLFU] Asynchronous and periodic metadata persistence to
  disk (`:metadata_persistence_timeout`).
- [Nebulex.Adapters.DiskLFU] Support for custom metadata per cache entry.
- [Nebulex.Adapters.DiskLFU] Queryable API supporting match-all, specific keys
  (`:in`), and expired entry queries (`:query => :expired`).
- [Nebulex.Adapters.DiskLFU] Default transaction support via
  `Nebulex.Adapter.Transaction`.
- [Nebulex.Adapters.DiskLFU] Comprehensive telemetry instrumentation for
  eviction, expired entry cleanup, metadata persistence, and load errors.
- [Nebulex.Adapters.DiskLFU] Flexible return options: `:binary` (default),
  `:metadata`, `:symlink` (read-only symbolic link), or custom function.
- [Nebulex.Adapters.DiskLFU] Crash recovery with metadata loading from disk on
  startup.
- [Nebulex.Adapters.DiskLFU] Checksum validation (SHA) for data integrity.
