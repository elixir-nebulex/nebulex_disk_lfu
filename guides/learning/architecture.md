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
- Managing metadata: `key`, `raw_key`, `checksum`, `size_bytes`,
  `access_count`, `inserted_at`, `last_accessed_at`, `expires_at`,
  and `metadata`.
- LFU-based eviction.
- TTL expiration handling.
- Atomic updates using `:global.trans/4` for per-key and cache-wide locking.
- Persist metadata to disk asynchronously and periodically (configurable).
  This enables concurrent reads since the metadata is not persisted
  immediately. The metadata is updated in memory, but it is dumped to disk
  later.

Files are stored on disk using SHA256-hashed keys:

- `HASH.cache` - contains the binary value
- `HASH.meta` - contains metadata in Erlang term format

Where `HASH` is the Base16-encoded SHA256 hash of the original key.

### 2. **Adapter Module (**`Nebulex.Adapters.DiskLFU`**)**

Implements the Nebulex adapter behavior:

- Delegates operations to `Store`
- Manages cache lifecycle (init, cleanup, child spec)
- Supports Nebulex features like `get`, `put`, `delete`, `has_key?`, `all`,
  `size`, etc.

### 3. **ETS + Counters for Performance**

- Metadata for all keys is loaded into an ETS table on startup
- A fast `:counters` instance tracks total size of the cache
- Concurrency-safe and highly efficient

---

## Eviction Strategy

The adapter implements **eager eviction** based on total disk usage:

- Configurable via `:max_bytes`.
- Triggered on `put/4` if the write would exceed the size limit

### Eviction Order

Eviction candidates are selected from ETS using a two-phase approach:

1. **Priority: Expired Entries** - First attempts to evict entries where
   `expires_at <= now()`, sorted by expiration time and size.
2. **Fallback: LFU Strategy** - If no expired entries exist, selects least
   frequently used entries, sorted by `access_count` (ascending) and
   `last_accessed_at` (oldest first).

Eviction is incremental:

- Uses `:ets.select` with a configurable sample size (`:eviction_victim_sample_size`)
- Evicts up to `:eviction_victim_limit` entries per operation
- Stops once enough space is reclaimed

### Atomicity

The adapter uses `:global.trans/4` with two-level locking:

1. **Per-key locking** - Individual operations (read, write, delete) acquire
   locks on specific keys to prevent concurrent modifications of the same entry.
2. **Cache-wide locking** - Eviction operations acquire a lock on the entire
   cache directory to prevent multiple concurrent evictions, which could lead
   to race conditions.

This ensures data consistency and prevents write conflicts under high
concurrency.

### Periodic Expiration Cleanup

In addition to the eager eviction mechanism triggered by size constraints, the
adapter supports **proactive background cleanup** of expired entries using the
`:eviction_timeout` option.

When `:eviction_timeout` is configured at startup, the Store process starts a
background timer that periodically runs and removes all expired entries from the
cache without requiring explicit API calls. This is useful for applications that
want to keep the cache clean without implementing their own background job.

**Configuration Example:**

```elixir
config :my_app, MyApp.Cache,
  root_path: "/tmp/my_cache",
  eviction_timeout: :timer.minutes(5)  # Clean expired entries every 5 minutes
```

**How It Works:**

1. The timer is set during Store initialization.
2. At each interval, a `:evict_expired_entries` message is sent to the Store
   process.
3. The Store locates all entries where `expires_at <= now()`.
4. Expired entries are removed from disk and their metadata is updated.
5. The cache size counter is decremented accordingly.
6. The timer is reset for the next interval.
7. The entire operation is wrapped in a telemetry span for observability.

**Alternative: Manual Cleanup**

If you prefer not to use background cleanup, you can manually evict expired
entries at any time using the queryable API:

```elixir
MyCache.delete_all(query: :expired)
```

This allows for more control over when cleanup occurs, such as during
low-traffic periods.

---

## TTL Expiration

Each entry supports a TTL (`expires_at` field in metadata). The adapter handles
expiration in multiple ways:

1. **Lazy expiration** - On `get`, if the entry is expired:
   - It is deleted (cache miss)
   - Metadata and file are removed

2. **Eager eviction** - During size-based eviction, expired entries are
   prioritized for removal before applying LFU strategy.

3. **Periodic cleanup** - When `:eviction_timeout` is configured, a background
   timer automatically removes all expired entries at the specified interval
   (see "Periodic Expiration Cleanup" section above).

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
  A1B2C3...XYZ.cache      # value as binary (SHA256 hash of key1)
  A1B2C3...XYZ.meta       # metadata: access_count, size, etc
  D4E5F6...UVW.cache      # value as binary (SHA256 hash of key2)
  D4E5F6...UVW.meta       # metadata for key2
```

Each file is named using the Base16-encoded SHA256 hash of the original key,
ensuring filesystem-safe names and avoiding collisions.

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

### Performance Optimizations

- **Replace `:global.trans` with local locking** - The current implementation uses
  `:global.trans/4` for atomic operations, which is designed for distributed
  systems. For single-node deployments, a local locking mechanism (e.g.,
  Registry-based or process-pool locks) would provide better performance at
  high concurrency.
- **Directory sharding** - All cache files currently reside in a single directory.
  For caches with 100K+ entries, filesystem performance may degrade. Sharding
  into subdirectories based on hash prefixes (e.g., first 2 characters) would
  improve scalability.
- **Incremental metadata persistence** - Current implementation persists all
  metadata entries periodically. Tracking and persisting only dirty entries
  would reduce I/O overhead for large caches.

### Feature Enhancements

- Smarter multi-tier eviction (e.g., based on age buckets)
- Optional compression for `.cache` files
- Support for `Nebulex.Adapters.Common.Info` behaviour (cache introspection)
- Support for `Nebulex.Adapter.Observable` behaviour (cache entry events)

---
