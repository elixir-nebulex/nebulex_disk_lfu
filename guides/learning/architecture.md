# Persistent LFU Cache Adapter for Nebulex

`Nebulex.Adapters.DiskLFU` is a
**persistent LFU (Least Frequently Used) cache adapter**
for [Nebulex](https://hexdocs.pm/nebulex), designed to provide an SSD-backed
cache with disk persistence, TTL support, and LFU-based eviction.
This adapter is ideal for workloads that require:

- High-capacity caching without exhausting memory.
- File-based persistence with cache recovery after restarts.
- Concurrency-safe operations for both reads and writes.
- Customizable eviction strategies.

---

## Architecture Overview

The adapter is composed of several key modules:

### 1. **Store Module ([Nebulex.Adapters.DiskLFU.Store][store_mod])**

[store_mod]: https://github.com/elixir-nebulex/nebulex_disk_lfu/blob/main/lib/nebulex/adapters/disk_lfu/store.ex

Responsible for:

- Disk read/write operations for `.cache` and `.meta` files
- Managing metadata: `access_count`, `inserted_at`, `expired_at`,
  and `size_bytes`.
- LFU-based eviction.
- TTL expiration handling.
- Atomic updates using `:global.trans/4`.
- Persist metadata to disk asynchronously and periodically (configurable).
  This will enable concurrent reads since the metadata is not persisted
  immediately. The metadata is updated in memory, but it is dumped to disk
  later.

Files are stored on disk as:

- `key.cache` - contains the binary value
- `key.meta` - contains metadata in Erlang term format

### 2. **Adapter Module (**`Nebulex.Adapters.DiskLFU`**)**

Implements the Nebulex adapter behavior:

- Delegates operations to `Store`
- Manages cache lifecycle (init, cleanup, child spec)
- Supports Nebulex features like `get`, `put`, `delete`, `has_key?`, `all`,
  `size`, etc.

### 4. **ETS + Counters for Performance**

- Metadata for all keys is loaded into an ETS table on startup
- A fast `:counters` instance tracks total size of the cache
- Concurrency-safe and highly efficient

---

## Eviction Strategy

The adapter implements **eager eviction** based on total disk usage:

- Configurable via `:max_bytes`.
- Triggered on `put/4` if the write would exceed the size limit

### Eviction Order

Eviction candidates are selected from ETS, ordered by:

1. Least `access_count`
2. Oldest `expired_at` (favoring expired entries)
3. Oldest `last_accessed_at`

Eviction is incremental:

- Uses `:ets.select` with a `:limit`
- Stops once enough space is reclaimed

### Atomicity

Eviction and counter updates are wrapped in `:global.trans/4` to ensure
serialization under concurrency.

---

## TTL Expiration

Each entry supports a TTL (`expired_at` field in metadata). On `get`, if the
entry is expired:

- It is deleted (cache miss)
- Metadata and file are removed

The adapter also supports TTL-based eviction during eager eviction.

### Optional Cleanup

You may implement background sweeping for expired keys using a scheduled task.
This is left to the user or future roadmap.

---

## Concurrency Model

The design favors **read concurrency**:

- Multiple processes can read `.cache` files concurrently.
- Reads use ETS for fast metadata access.
- Writes and evictions are serialized for safety.

Atomic disk writes are ensured by:

- Using temporary files and atomic `File.rename/2`.
- Serialized eviction logic.

---

## File Structure Example

```
/root_path/
  key1.cache      # value as binary
  key1.meta       # metadata: access_count, size, etc
  key2.cache
  key2.meta
```

---

## Configuration

```elixir
defmodule MyApp.Cache do
  use Nebulex.Cache,
    otp_app: :my_app,
    adapter: Nebulex.Adapters.DiskLFU
end
```

```elixir
config :my_app, MyCache,
  root_path: "/tmp/my_cache",
  max_bytes: 10_000_000,  # 10MB
```

---

## Future Enhancements

- Background cleanup of expired keys
- Smarter multi-tier eviction (e.g., based on age buckets)
- Optional compression for `.cache` files
- Metrics and observability improvements

---
