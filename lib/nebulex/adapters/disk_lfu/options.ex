defmodule Nebulex.Adapters.DiskLFU.Options do
  @moduledoc false

  alias Nebulex.Cache.Options, as: NbxOptions

  # Start options
  start_opts = [
    root_path: [
      type: :string,
      required: true,
      doc: """
      The root directory where cache files are stored.

      Cache files (`.cache` and `.meta` files) are created as direct children
      of this directory. This directory will be created if it does not exist.
      """
    ],
    max_bytes: [
      type: {:or, [:pos_integer, nil]},
      required: false,
      default: nil,
      doc: """
      The maximum cache size in bytes. When exceeded, LFU eviction is triggered.

      When `nil` (default), the cache has no size-based eviction limit.
      """
    ],
    eviction_victim_limit: [
      type: :pos_integer,
      required: false,
      default: 100,
      doc: """
      The maximum number of entries to evict in a single operation.

      When size limit is exceeded, eviction selects up to this many entries
      (victims) to delete based on the LFU strategy.
      """
    ],
    eviction_victim_sample_size: [
      type: :pos_integer,
      required: false,
      default: 1000,
      doc: """
      The number of candidate entries to sample when selecting victims.

      A larger sample size provides better eviction decisions (more accurate LFU)
      but requires more scanning. The sampled entries are then sorted by
      frequency and age, and the worst `:eviction_victim_limit` entries are
      removed.
      """
    ],
    metadata_persistence_timeout: [
      type: {:or, [:timeout, nil]},
      required: false,
      default: :timer.minutes(1),
      doc: """
      The interval in milliseconds at which to persist metadata to disk.

      Metadata is updated in memory for performance, then periodically written
      to disk at this interval to minimize I/O overhead. When `nil`, metadata
      is not persisted automatically (only on shutdown).
      """
    ],
    eviction_timeout: [
      type: {:or, [:timeout, nil]},
      required: false,
      default: nil,
      doc: """
      The interval in milliseconds to evict expired entries periodically.

      When set, a background timer triggers automatic cleanup of all expired
      entries at the specified interval. When `nil` (default), expired entries
      are removed lazily (on access) or manually via `delete_all(query: :expired)`.

      **Example:**

      ```elixir
      config :my_app, MyApp.Cache,
        root_path: "/tmp/my_cache",
        eviction_timeout: :timer.minutes(5)
      ```
      """
    ]
  ]

  # Common runtime options
  common_runtime_opts = [
    retries: [
      type: :timeout,
      required: false,
      default: :infinity,
      doc: """
      The number of times to retry an operation if it fails due to contention.

      Retries occur when concurrent operations lock the same key or resource.
      Set to `:infinity` to retry indefinitely (default).
      """
    ]
  ]

  # Read options
  read_opts = [
    return: [
      type: {:or, [{:in, [:binary, :metadata, :symlink]}, {:fun, 2}]},
      required: false,
      default: :binary,
      doc: """
      The value to return from read operations (`fetch`, `get`, `take`).

      Supported values:

      - `:binary` (default) - Returns the cache value as a binary.
      - `:metadata` - Returns the entry metadata instead of the value.
      - `:symlink` - Returns a temporary read-only symlink to the file.
        **Only supported for `fetch` and `get` operations.** Modifying the file
        can cause unexpected behavior.
      - A function/2 - A callback receiving `(binary, metadata)` that transforms
        and returns a custom value.

      """
    ]
  ]

  # Write options
  write_opts = [
    metadata: [
      type: :map,
      required: false,
      default: %{},
      doc: """
      Custom metadata to attach to the cached entry.

      This data is stored alongside the value and can be retrieved using
      the `return: :metadata` option on read operations.
      """
    ]
  ]

  # Start options schema
  @start_opts_schema NimbleOptions.new!(start_opts)

  # Common runtime options schema
  @common_runtime_opts_schema NimbleOptions.new!(common_runtime_opts)

  # Read options schema
  @read_opts_schema NimbleOptions.new!(common_runtime_opts ++ read_opts)

  # Write options schema
  @write_opts_schema NimbleOptions.new!(common_runtime_opts ++ write_opts)

  # Nebulex common options
  @nbx_start_opts NbxOptions.__compile_opts__() ++ NbxOptions.__start_opts__()

  ## Docs API

  # coveralls-ignore-start

  @spec start_options_docs() :: binary()
  def start_options_docs do
    NimbleOptions.docs(@start_opts_schema)
  end

  @spec common_runtime_options_docs() :: binary()
  def common_runtime_options_docs do
    NimbleOptions.docs(@common_runtime_opts_schema)
  end

  @spec read_options_docs() :: binary()
  def read_options_docs do
    @read_opts_schema.schema
    |> Keyword.drop(Keyword.keys(@common_runtime_opts_schema.schema))
    |> NimbleOptions.docs()
  end

  @spec write_options_docs() :: binary()
  def write_options_docs do
    @write_opts_schema.schema
    |> Keyword.drop(Keyword.keys(@common_runtime_opts_schema.schema))
    |> NimbleOptions.docs()
  end

  # coveralls-ignore-stop

  ## Validation API

  @spec validate_start_opts!(keyword()) :: keyword()
  def validate_start_opts!(opts) do
    adapter_opts =
      opts
      |> Keyword.drop(@nbx_start_opts)
      |> NimbleOptions.validate!(@start_opts_schema)

    Keyword.merge(opts, adapter_opts)
  end

  @spec validate_common_runtime_opts!(keyword()) :: keyword()
  def validate_common_runtime_opts!(opts) do
    adapter_opts =
      opts
      |> Keyword.drop(NbxOptions.__runtime_shared_opts__())
      |> NimbleOptions.validate!(@common_runtime_opts_schema)

    Keyword.merge(opts, adapter_opts)
  end

  @spec validate_read_opts!(keyword()) :: keyword()
  def validate_read_opts!(opts) do
    adapter_opts =
      opts
      |> Keyword.drop(NbxOptions.__runtime_shared_opts__())
      |> NimbleOptions.validate!(@read_opts_schema)

    Keyword.merge(opts, adapter_opts)
  end

  @spec validate_write_opts!(keyword()) :: keyword()
  def validate_write_opts!(opts) do
    adapter_opts =
      opts
      |> Keyword.drop(NbxOptions.__runtime_shared_opts__())
      |> NimbleOptions.validate!(@write_opts_schema)

    Keyword.merge(opts, adapter_opts)
  end
end
