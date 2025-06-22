defmodule Nebulex.Adapters.DiskLFU.Options do
  @moduledoc false

  # Start options
  start_opts = [
    base_dir: [
      type: :string,
      required: false,
      default: "cache",
      doc: """
      The base directory to store the cache files.
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
    ],
    modes: [
      type: {:list, :atom},
      required: false,
      default: [],
      doc: """
      The modes to write the binary to disk.
      """
    ]
  ]

  # Start options schema
  @start_opts_schema NimbleOptions.new!(start_opts)

  # Common runtime options schema
  @common_runtime_opts_schema NimbleOptions.new!(common_runtime_opts)

  # Nebulex common options
  @nbx_start_opts Nebulex.Cache.Options.__compile_opts__() ++ Nebulex.Cache.Options.__start_opts__()

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
      |> Keyword.take([:retries, :modes])
      |> NimbleOptions.validate!(@common_runtime_opts_schema)

    Keyword.merge(opts, adapter_opts)
  end
end
