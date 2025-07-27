defmodule Nebulex.Adapters.DiskLFU.Options do
  @moduledoc false

  alias Nebulex.Cache.Options, as: NbxOptions

  # Start options
  start_opts = [
    root_path: [
      type: :string,
      required: true,
      doc: """
      The root path to store the cache files.
      """
    ],
    max_bytes: [
      type: {:or, [:pos_integer, nil]},
      required: false,
      default: nil,
      doc: """
      The maximum number of bytes to store in the cache.

      If not provided, the cache will not evict entries based on the total
      size of the cache (default).
      """
    ],
    eviction_victim_limit: [
      type: :pos_integer,
      required: false,
      default: 100,
      doc: """
      The maximum number of eviction victims to delete.
      """
    ],
    eviction_victim_sample_size: [
      type: :pos_integer,
      required: false,
      default: 1000,
      doc: """
      The size of the sample to select the eviction victims from. After the
      sample is selected, the victims are sorted by the access count and the
      last accessed time. Then, the first victims given by
      `:eviction_victim_limit` are evicted.
      """
    ],
    metadata_persistence_timeout: [
      type: {:or, [:timeout, nil]},
      required: false,
      default: :timer.minutes(1),
      doc: """
      The timeout in milliseconds to persist the metadata to disk.
      When `nil`, the metadata is not persisted to disk.
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
      The number of times to retry a command if it fails because of a lock.
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
      The return value of the fetch operation.

      The following values are supported:

      - `:binary` - Returns the binary value.
      - `:metadata` - Returns the metadata.
      - `:symlink` - Returns a temporary symlink to the file. Be careful,
        the file should be only for read-only access. Any change to the file
        can cause unexpected behavior. This option is only supported for the
        operations: `fetch` and `get`
      - `t:Nebulex.Adapters.DiskLFU.return_fn/0` - An anonymous function
        that receives the binary value and the metadata and returns the
        desired value.

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
      The metadata to store with the value.
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
