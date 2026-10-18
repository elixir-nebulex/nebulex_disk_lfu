# Architecture

This guide covers what the code and the module docs do not: how the modules
split responsibility and the non-negotiable rules for every change. Read the
"Non-Negotiables" section at session start; read the rest before structural
changes.

For how the adapter works and how to configure it, read:

- `Nebulex.Adapters.DiskLFU` - options, the Query API, limitations, and the
  telemetry events.
- The ["Architecture" guide](../guides/learning/architecture.md) - the on-disk
  layout, the eviction strategy, TTL expiration, and the concurrency model.

For the broader Nebulex context (the adapter pattern, behaviour contracts,
and shared non-negotiables), read the
[core Nebulex architecture guide][core-arch].

[core-arch]: https://hexdocs.pm/nebulex/architecture.html

---

## Purpose

`nebulex_disk_lfu` is a persistent cache adapter: entries live in files on
disk, with the metadata in ETS, and the cache evicts the least frequently
used entries when it reaches its size limit. It keeps data across restarts,
which the in-memory adapters cannot.

---

## Module Boundaries

This section covers how the modules split responsibility; the file layout
is in `lib/` and `test/`.

- `Nebulex.Adapters.DiskLFU` is the adapter entry point. It implements the
  behaviours, validates the options, delegates storage to `Store`, and owns
  the transaction implementation (`:global` locks with a transaction
  namespace, separate from the store's internal locks).
- `Store` is the GenServer that owns the cache directory: it reads and
  writes the `.cache` and `.meta` files, keeps the metadata in ETS and the
  total size in `:counters`, runs the LFU eviction and the periodic expired
  entry cleanup, and persists the metadata to disk asynchronously.
- `Meta` is the metadata struct stored for each entry; `Helpers` holds the
  shared helpers; `Options` and `Transaction.Options` hold the NimbleOptions
  schemas.

---

## Non-Negotiables

These rules apply in addition to the shared non-negotiables in the core
Nebulex architecture guide.

### 1. Writes stay atomic and reads stay concurrent

Files are written through a temporary file and an atomic `File.rename/2`,
writes and evictions are serialized with `:global` locks (per key, and
cache-wide for eviction), and reads do not take locks. Any change to
`Store` keeps these properties and is tested under concurrency.

### 2. The on-disk format is a contract

Entries written by one release must be readable by the next. A change to
the `.cache` or `.meta` files, the key hashing, or the `Meta` struct needs
a migration path and a test that reads data written in the old format.

### 3. Optional deps must remain optional

`:telemetry` is optional. No code path in the adapter may raise or fail
when it is absent.

### 4. Keep this document up to date

After any structural change (changing the module boundaries, the on-disk
layout, or adding a non-negotiable), review this document and the
"Architecture" guide and update them if needed. Do not copy here what the
module docs already say; link to them. A stale architecture guide is worse
than no guide.

### 5. `mix precommit` must pass

```bash
mix precommit
```

It includes the docs build with warnings as errors; fix the root cause of a
docs warning, do not suppress it. Sobelow skips `Traversal.FileModule` on
purpose: the adapter's job is to read and write files under the configured
root path.

### 6. Read why before changing subtle behavior

The reasons behind the subtle behavior (the two-level locking, the eviction
order, the asynchronous metadata persistence) are in the "Architecture"
guide, the module docs, the code comments, and the tests. Read them, and the
history (`git log -S`), before changing that code. Do not reverse such
behavior without a test that covers the original problem.

---

## Further Reading

- [Core Nebulex Architecture](https://hexdocs.pm/nebulex/architecture.html)
- [Creating a New Adapter](https://hexdocs.pm/nebulex/creating-new-adapter.html)
- [nebulex_disk_lfu HexDocs](https://hexdocs.pm/nebulex_disk_lfu)
