defmodule Nebulex.Adapters.DiskLFU do
  @moduledoc """
  `Nebulex.Adapters.DiskLFU` is a
  **persistent LFU (Least Frequently Used) cache adapter** for
  [Nebulex](https://hexdocs.pm/nebulex), designed to provide an SSD-backed
  cache with disk persistence, TTL support, and LFU-based eviction.

  This adapter is ideal for workloads that require:

  - High-capacity caching without exhausting memory.
  - File-based persistence with cache recovery after restarts.
  - Concurrency-safe operations for both reads and writes.
  - Customizable eviction strategies.

  For example, imagine an application that downloads large files from S3 to
  process them. These files are reusable across different operations or
  requests. In such cases, it can be significantly more efficient to cache the
  files locally—ideally on an SSD—rather than repeatedly fetching them from S3.
  Using `Nebulex.Adapters.DiskLFU`, these files can be stored and accessed from
  the local file system with LFU eviction and TTL handling, reducing latency
  and cloud egress costs.

  See the [Architecture](architecture.html) document for more information.

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

  ## Startup options

  The following options are available for the adapter at startup:

  #{Nebulex.Adapters.DiskLFU.Options.start_options_docs()}

  ## Shared runtime options

  The following options are available for all operations:

  #{Nebulex.Adapters.DiskLFU.Options.common_runtime_options_docs()}

  ## Read options

  The following options are available for the read operations
  (e.g., `fetch`, `get`, `take`):

  #{Nebulex.Adapters.DiskLFU.Options.read_options_docs()}

  ## Write options

  The following options are available for the write operations
  (e.g., `put`, `put_new`, `replace`, `put_all`, `put_new_all`):

  #{Nebulex.Adapters.DiskLFU.Options.write_options_docs()}

  ## Adapter-specific telemetry events

  This adapter exposes the following Telemetry events grouped by category:

  ### Eviction Events

  * `telemetry_prefix ++ [:eviction, :start]` - Dispatched when eviction begins.

    * Measurements: `%{system_time: non_neg_integer()}`
    * Metadata:

      ```
      %{
        stored_bytes: non_neg_integer(),
        max_bytes: non_neg_integer(),
        victim_sample_size: non_neg_integer(),
        victim_limit: non_neg_integer()
      }
      ```

  * `telemetry_prefix ++ [:eviction, :stop]` - Dispatched when eviction
    completes.

    * Measurements: `%{duration: non_neg_integer()}`
    * Metadata:

      ```
      %{
        stored_bytes: non_neg_integer(),
        max_bytes: non_neg_integer(),
        victim_sample_size: non_neg_integer(),
        victim_limit: non_neg_integer(),
        result: term()
      }
      ```

  * `telemetry_prefix ++ [:eviction, :exception]` - Dispatched when eviction
    fails.

    * Measurements: `%{duration: non_neg_integer()}`
    * Metadata:

      ```
      %{
        stored_bytes: non_neg_integer(),
        max_bytes: non_neg_integer(),
        victim_sample_size: non_neg_integer(),
        victim_limit: non_neg_integer(),
        kind: :error | :exit | :throw,
        reason: term(),
        stacktrace: [term()]
      }
      ```

  ### Expired Entry Eviction Events

  * `telemetry_prefix ++ [:evict_expired_entries, :start]` - Dispatched when
    the periodic background timer begins evicting expired entries.

    * Measurements: `%{system_time: non_neg_integer()}`
    * Metadata:

      ```
      %{
        store_pid: pid()
      }
      ```

  * `telemetry_prefix ++ [:evict_expired_entries, :stop]` - Dispatched when
    expired entry eviction completes.

    * Measurements: `%{duration: non_neg_integer()}`
    * Metadata:

      ```
      %{
        store_pid: pid(),
        count: non_neg_integer()
      }
      ```

  * `telemetry_prefix ++ [:evict_expired_entries, :exception]` - Dispatched when
    expired entry eviction fails.

    * Measurements: `%{duration: non_neg_integer()}`
    * Metadata:

      ```
      %{
        store_pid: pid(),
        kind: :error | :exit | :throw,
        reason: term(),
        stacktrace: [term()]
      }
      ```

  ### Metadata Persistence Events

  * `telemetry_prefix ++ [:persist_meta, :start]` - Dispatched when metadata
    persistence begins.

    * Measurements: `%{system_time: non_neg_integer()}`
    * Metadata:

      ```
      %{
        store_pid: pid()
      }
      ```

  * `telemetry_prefix ++ [:persist_meta, :stop]` - Dispatched when metadata
    persistence completes.

    * Measurements: `%{duration: non_neg_integer()}`
    * Metadata:

      ```
      %{
        store_pid: pid(),
        count: non_neg_integer()
      }
      ```

  * `telemetry_prefix ++ [:persist_meta, :exception]` - Dispatched when metadata
    persistence fails.

    * Measurements: `%{duration: non_neg_integer()}`
    * Metadata:

      ```
      %{
        store_pid: pid(),
        kind: :error | :exit | :throw,
        reason: term(),
        stacktrace: [term()]
      }
      ```

  ### Metadata Loading Events

  * `telemetry_prefix ++ [:load_metadata, :error]` - Dispatched when metadata
    loading fails for a file.

    * Measurements: `%{system_time: non_neg_integer()}`
    * Metadata:

      ```
      %{
        filename: String.t(),
        reason: term()
      }
      ```

  ## Queryable API

  This adapter supports the `Nebulex.Adapter.Queryable` behaviour with a limited
  query interface. The following query options are available for queryable
  operations like `delete_all/2`, `count_all/2`, and `get_all/2`:

  ### Query Option: Match All Keys

  Delete, count, or retrieve all keys in the cache:

  ```elixir
  MyCache.delete_all()
  MyCache.count_all()
  MyCache.get_all()
  ```

  ### Query Option: Match Specific Keys

  Delete, count, or retrieve specific keys using the `in` operator:

  ```elixir
  MyCache.delete_all(in: [:key1, :key2, :key3])
  MyCache.count_all(in: [:key1, :key2])
  MyCache.get_all(in: [:key1, :key2, :key3])
  ```

  ### Query Option: Match Expired Entries

  Delete expired entries using `query: :expired`:

  ```elixir
  MyCache.delete_all(query: :expired)
  ```

  This query matches all entries whose TTL (`expires_at`) is less than or equal
  to the current time. It is only supported for `delete_all/2` and is
  particularly useful for proactive cleanup of stale entries, either manually
  via the API or automatically by configuring the `:eviction_timeout` option
  at startup.

  For more information about automatic eviction, see the
  [Architecture](http://hexdocs.pm/nebulex_disk_lfu/architecture.html) guide.

  ## Limitations and Considerations

  ### Unsupported Operations

  - `incr/3` and `decr/3` are not supported.
  - `put_new/3`, `replace/3`, and `put_new_all/2` are not supported. They work
    as `put` operations instead. Support is planned for a future release.
  - The `Nebulex.Adapters.Common.Info` behaviour is not implemented. Support
    for cache introspection and statistics is planned for a future release.
  - The `Nebulex.Adapter.Observable` behaviour is not implemented. Support for
    cache entry events is planned for a future release.

  ### Query Operation Limitations

  - `count_all/1` supports counting all keys or given keys, but is **not atomic**.
    Errors are skipped and the count may be inaccurate.
  - `delete_all/1` supports deleting all keys, given keys, or expired entries
    (`query: :expired`), but is **not atomic**. Errors are skipped and deletion
    may be incomplete.
  - `get_all/1` supports retrieving all keys or given keys only.
  - `stream/1` supports streaming all keys or given keys only.

  ### Performance Characteristics

  - Write and delete operations (`put`, `put_all`, `delete`, `take`) are
    **blocking and atomic per key**. This ensures consistency and prevents
    race conditions or write conflicts.
  - Read operations may block briefly if a key is expired and requires cleanup
    from the cache.

  """

  # Provide Cache Implementation
  @behaviour Nebulex.Adapter
  @behaviour Nebulex.Adapter.KV
  @behaviour Nebulex.Adapter.Queryable

  # Inherit default transaction implementation
  use Nebulex.Adapter.Transaction

  import Nebulex.Adapter
  import Nebulex.Adapters.DiskLFU.Helpers
  import Nebulex.Time, only: [now: 0]
  import Nebulex.Utils

  alias __MODULE__.{Meta, Options, Store}

  @typedoc "The return function for the fetch operation."
  @type return_fn() :: (binary(), Meta.t() -> any())

  ## Nebulex.Adapter

  @impl true
  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Returns the cache directory for the given cache name.
      """
      @spec cache_path(atom()) :: String.t()
      def cache_path(name \\ __MODULE__) do
        name
        |> lookup_meta()
        |> Map.fetch!(:cache_path)
      end
    end
  end

  @impl true
  def init(opts) do
    # Get the cache module from the options
    {cache, opts} = Keyword.pop!(opts, :cache)

    # Validate options
    opts = Options.validate_start_opts!(opts)

    # Get the required options
    {root_path, opts} = Keyword.pop!(opts, :root_path)
    name = opts[:name] || cache
    cache_path = Path.join(root_path, to_string(name))

    # Create the adapter meta
    adapter_meta = %{
      name: name,
      root_path: root_path,
      cache_path: cache_path,
      meta_table: camelize_and_concat([name, "Meta"]),
      bytes_counter: :counters.new(1, [:write_concurrency]),
      max_bytes: Keyword.fetch!(opts, :max_bytes),
      eviction_victim_sample_size: Keyword.fetch!(opts, :eviction_victim_sample_size),
      eviction_victim_limit: Keyword.fetch!(opts, :eviction_victim_limit),
      metadata_persistence_timeout: Keyword.fetch!(opts, :metadata_persistence_timeout),
      eviction_timeout: Keyword.fetch!(opts, :eviction_timeout)
    }

    # Create the child spec for the store
    child_spec =
      Supervisor.child_spec(
        {Store, Map.put(adapter_meta, :telemetry_prefix, Keyword.fetch!(opts, :telemetry_prefix))},
        id: {__MODULE__, camelize_and_concat([name, Store])}
      )

    {:ok, child_spec, adapter_meta}
  end

  ## Nebulex.Adapter.KV

  @impl true
  def fetch(%{cache_path: cache_path} = adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_read_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)
    return = Keyword.fetch!(opts, :return)

    result =
      if return in [:metadata, :symlink] do
        Store.fetch_meta(adapter_meta, key, retries)
      else
        Store.read_from_disk(adapter_meta, key, retries)
      end

    with {:ok, _} = ok <- result do
      handle_return(return, ok, cache_path)
    end
    |> handle_result(key, "could not fetch key #{inspect(key)}")
  end

  @impl true
  def put(adapter_meta, key, value, _on_write, ttl, _keep_ttl?, opts) do
    assert_binary(key, "key")
    assert_binary(value, "value")

    opts =
      opts
      |> Options.validate_write_opts!()
      |> Keyword.put(:ttl, ttl)

    with {:ok, _} <- Store.write_to_disk(adapter_meta, key, value, opts) do
      {:ok, true}
    end
    |> handle_result(:"$no_ctx", "could not put key #{inspect(key)}")
  end

  @impl true
  def put_all(adapter_meta, entries, _on_write, ttl, opts) do
    opts =
      opts
      |> Options.validate_write_opts!()
      |> Keyword.put(:ttl, ttl)

    entries
    |> Stream.map(fn {key, value} ->
      assert_binary(key, "key")
      assert_binary(value, "value")

      {key, value}
    end)
    |> Enum.reduce_while(:ok, fn {key, value}, acc ->
      case Store.write_to_disk(adapter_meta, key, value, opts) do
        {:ok, _} -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> handle_result(:"$no_ctx", "could not put all keys")
  end

  @impl true
  def delete(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    adapter_meta
    |> Store.delete_from_disk(key, retries)
    |> handle_result(key, "could not delete key #{inspect(key)}")
  end

  @impl true
  def take(%{cache_path: cache_path} = adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_read_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)
    return = Keyword.fetch!(opts, :return)

    result =
      if return == :metadata do
        Store.pop_meta(adapter_meta, key, retries)
      else
        Store.pop_from_disk(adapter_meta, key, retries)
      end

    with {:ok, _} = ok <- result do
      handle_return(return, ok, cache_path)
    end
    |> handle_result(key, "could not take key #{inspect(key)}")
  end

  @impl true
  def has_key?(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    case Store.fetch_meta(adapter_meta, key, retries) do
      {:ok, _} ->
        {:ok, true}

      {:error, reason} when reason in [:not_found, :expired] ->
        {:ok, false}

      {:error, _} = error ->
        handle_result(error, :"$no_ctx", "could not check if key #{inspect(key)} exists")
    end
  end

  @impl true
  def ttl(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    with {:ok, %Meta{expires_at: expires_at}} <- Store.fetch_meta(adapter_meta, key, retries) do
      {:ok, remaining_ttl(expires_at)}
    end
    |> handle_result(key, "could not get TTL for key #{inspect(key)}")
  end

  @impl true
  def expire(adapter_meta, key, ttl, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    Store.update_meta(
      adapter_meta,
      key,
      retries,
      &%{&1 | expires_at: expires_at(ttl)}
    )
    |> handle_update_meta("could not expire key #{inspect(key)}")
  end

  @impl true
  def touch(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    adapter_meta
    |> Store.update_meta(key, retries, &%{&1 | last_accessed_at: now()})
    |> handle_update_meta("could not touch key #{inspect(key)}")
  end

  @impl true
  def update_counter(_adapter_meta, _key, _amount, _default, _ttl, _opts) do
    # TODO: Maybe implement this in the future
    wrap_error Nebulex.Error, reason: :not_supported
  end

  ## Nebulex.Adapter.Queryable

  @impl true
  def execute(adapter_meta, query_meta, opts)

  def execute(
        %{meta_table: meta_table},
        %{op: :count_all, query: {:q, nil}},
        _opts
      ) do
    {:ok, Store.count_all(meta_table)}
  end

  def execute(
        %{meta_table: meta_table},
        %{op: :count_all, query: {:in, keys}},
        _opts
      ) do
    count =
      Enum.reduce(keys, 0, fn key, acc ->
        if Store.exists?(meta_table, key) do
          acc + 1
        else
          acc
        end
      end)

    {:ok, count}
  end

  def execute(
        %{meta_table: meta_table, cache_path: cache_path},
        %{op: :delete_all, query: {:q, nil}},
        opts
      ) do
    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    {:ok, Store.delete_all_from_disk(meta_table, cache_path, retries)}
  end

  def execute(adapter_meta, %{op: :delete_all, query: {:q, :expired}}, opts) do
    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    {:ok, Store.delete_expired_entries_from_disk(adapter_meta, retries)}
  end

  def execute(
        adapter_meta,
        %{op: :delete_all, query: {:in, keys}},
        opts
      ) do
    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    count =
      Enum.reduce(keys, 0, fn key, acc ->
        case Store.delete_from_disk(adapter_meta, key, retries) do
          :ok -> acc + 1
          {:error, _} -> acc
        end
      end)

    {:ok, count}
  end

  def execute(
        %{meta_table: meta_table},
        %{op: :get_all, query: {:q, nil}},
        _opts
      ) do
    {:ok, Store.get_all_keys(meta_table)}
  end

  def execute(
        %{meta_table: meta_table},
        %{op: :get_all, query: {:in, keys}},
        _opts
      ) do
    {:ok, Store.get_all_keys(meta_table, keys)}
  end

  def execute(_adapter_meta, %{op: op, query: query}, _opts) do
    # TODO: Support more queries in the future
    # E.g., `{:q, match_spec}`
    raise ArgumentError, "`#{op}` does not support query: #{inspect(query)}"
  end

  @impl true
  def stream(adapter_meta, query, opts) do
    stream =
      Stream.resource(
        fn ->
          execute(adapter_meta, %{query | op: :get_all}, opts)
        end,
        fn
          {:ok, results} -> {results, :halt}
          :halt -> {:halt, []}
        end,
        & &1
      )

    {:ok, stream}
  end

  ## Private functions

  defp assert_binary(data, arg_name) do
    unless is_binary(data) do
      raise ArgumentError, "the #{arg_name} must be a binary, got: #{inspect(data)}"
    end
  end

  defp handle_result(result, ctx, msg)

  defp handle_result({:error, reason}, key, _) when reason in [:not_found, :expired] do
    wrap_error Nebulex.KeyError, key: key, reason: reason
  end

  defp handle_result({:error, :enoent}, key, _) when key != :"$no_ctx" do
    wrap_error Nebulex.KeyError, key: key, reason: :not_found
  end

  @posix_errors ~w(
    eacces eagain ebadf ebadmsg ebusy edeadlk edeadlock edquot eexist efault
    efbig eftype eintr einval eio eisdir eloop emfile emlink emultihop
    enametoolong enfile enobufs enodev enolck enolink enoent enomem enospc
    enosr enostr enosys enotblk enotdir enotsup enxio eopnotsupp eoverflow
    eperm epipe erange erofs espipe esrch estale etxtbsy exdev)a
  defp handle_result({:error, reason}, _, msg) when reason in @posix_errors do
    wrap_error Nebulex.Error, module: __MODULE__, reason: reason, prefix: msg
  end

  defp handle_result({:error, reason}, _, _) do
    wrap_error Nebulex.Error, reason: reason
  end

  defp handle_result(other, _, _) do
    other
  end

  defp handle_return(:binary, {:ok, {binary, _meta}}, _) do
    {:ok, binary}
  end

  defp handle_return(:metadata, {:ok, %Meta{metadata: meta}}, _) do
    {:ok, meta}
  end

  defp handle_return(:symlink, {:ok, %Meta{key: key}}, cache_path) do
    # Get the real path for the key
    hash_key = hash_key(key)
    real_path = Path.join(cache_path, hash_key <> ".cache")

    # Symlink path to the current directory
    temp_path = "cache-symlinks/#{:erlang.phash2(cache_path)}"
    File.mkdir_p!(temp_path)
    link_path = Path.join(temp_path, hash_key <> ".cache")

    # Instead of exposing internal paths, create a temporary symlink into
    # a user-facing directory
    case File.ln_s(real_path, link_path) do
      :ok -> {:ok, link_path}
      {:error, :eexist} -> {:ok, link_path}
      error -> error
    end
  end

  defp handle_return(fun, {:ok, {binary, %Meta{metadata: meta}}}, _) when is_function(fun, 2) do
    {:ok, fun.(binary, meta)}
  end

  defp handle_update_meta(result, msg) do
    case result do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> handle_result(error, :"$no_ctx", msg)
    end
  end

  ## Error formatting

  @doc false
  def format_error(reason, metadata) do
    prefix = Keyword.fetch!(metadata, :prefix)

    formatted =
      reason
      |> :file.format_error()
      |> IO.iodata_to_binary()

    "#{prefix}: #{formatted}"
  end
end
