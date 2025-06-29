defmodule Nebulex.Adapters.DiskLFU do
  @moduledoc """
  `Nebulex.Adapters.DiskLFU` is a
  **persistent LFU (Least Frequently Used) cache adapter** for
  [Nebulex](https://hexdocs.pm/nebulex), designed to provide an SSD-backed
  cache with disk persistence, TTL support, and LFU-based eviction.
  his adapter is ideal for workloads that require:

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

  See the [Architecture](http://hexdocs.pm/nebulex_disk_lfu/architecture.html)
  document for more information.

  ## Options

  The adapter supports the following options:

  #{Nebulex.Adapters.DiskLFU.Options.start_options_docs()}

  ## Shared options

  The adapter supports the following options for all operations:

  #{Nebulex.Adapters.DiskLFU.Options.common_runtime_options_docs()}

  ## Read options

  The following options are available for the read operations
  (e.g., `fetch`, `get`, `take`):

  #{Nebulex.Adapters.DiskLFU.Options.read_options_docs()}

  ## Write options

  The following options are available for the write operations
  (e.g., `put`, `put_new`, `replace`, `put_all`, `put_new_all`):

  #{Nebulex.Adapters.DiskLFU.Options.write_options_docs()}

  """

  # Provide Cache Implementation
  @behaviour Nebulex.Adapter
  @behaviour Nebulex.Adapter.KV
  @behaviour Nebulex.Adapter.Queryable

  import Nebulex.Adapter
  import Nebulex.Adapters.DiskLFU.Helpers
  import Nebulex.Time, only: [now: 0]
  import Nebulex.Utils

  alias __MODULE__.{Meta, Options, Store}

  @typedoc "The return function of the fetch operation."
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
      eviction_select_limit: Keyword.fetch!(opts, :eviction_select_limit),
      eviction_victims_limit: Keyword.fetch!(opts, :eviction_victims_limit)
    }

    # Create the child spec for the store
    child_spec =
      Supervisor.child_spec(
        {Store, cache_name: name, cache_path: cache_path},
        id: {__MODULE__, camelize_and_concat([name, Store])}
      )

    {:ok, child_spec, adapter_meta}
  end

  ## Nebulex.Adapter.KV

  @impl true
  def fetch(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_read_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)
    return = Keyword.fetch!(opts, :return)

    with {:ok, {binary, %Meta{metadata: meta}}} <-
           Store.read_from_disk(adapter_meta, key, retries) do
      handle_return(return, {binary, meta})
    end
    |> handle_result(key)
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
      :ok
    end
    |> handle_result()
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
    |> handle_result()
  end

  @impl true
  def delete(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    adapter_meta
    |> Store.delete_from_disk(key, retries)
    |> handle_result(key)
  end

  @impl true
  def take(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_read_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)
    return = Keyword.fetch!(opts, :return)

    with {:ok, {binary, %Meta{metadata: meta}}} <-
           Store.pop_from_disk(adapter_meta, key, retries) do
      handle_return(return, {binary, meta})
    end
    |> handle_result(key)
  end

  @impl true
  def has_key?(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    case Store.fetch_meta(adapter_meta, key, retries) do
      {:ok, _} -> {:ok, true}
      {:error, reason} when reason in [:not_found, :expired] -> {:ok, false}
      {:error, _} = error -> handle_result(error)
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
    |> handle_result(key)
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
    |> handle_update_meta()
  end

  @impl true
  def touch(adapter_meta, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    adapter_meta
    |> Store.update_meta(key, retries, &%{&1 | last_accessed_at: now()})
    |> handle_update_meta()
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
        %{meta_table: meta_table, cache_path: cache_path},
        %{op: :delete_all, query: {:q, nil}},
        _opts
      ) do
    {:ok, Store.delete_all_from_disk(meta_table, cache_path)}
  end

  def execute(
        %{meta_table: meta_table},
        %{op: :get_all, query: {:q, nil}},
        _opts
      ) do
    {:ok, Store.get_all_keys(meta_table)}
  end

  def execute(_adapter_meta, %{op: op, query: query}, _opts) do
    # TODO: Support more queries in the future
    # E.g., `{:in, [...]}`, `{:q, match_spec}`, etc.
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

  defp handle_result(result, ctx \\ :"$no_ctx")

  defp handle_result({:error, reason}, key) when reason in [:not_found, :expired] do
    wrap_error Nebulex.KeyError, key: key, reason: reason
  end

  defp handle_result({:error, :enoent}, key) when key != :"$no_ctx" do
    wrap_error Nebulex.KeyError, key: key, reason: :not_found
  end

  defp handle_result({:error, reason}, _) do
    wrap_error Nebulex.Error, reason: reason
  end

  defp handle_result(other, _) do
    other
  end

  defp handle_return(:binary, {binary, _meta}) do
    {:ok, binary}
  end

  defp handle_return(:metadata, {_binary, meta}) do
    {:ok, meta}
  end

  defp handle_return(fun, {binary, meta}) when is_function(fun, 2) do
    {:ok, fun.(binary, meta)}
  end

  defp handle_update_meta(result) do
    case result do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> handle_result(error)
    end
  end

  defp assert_binary(data, arg_name) do
    unless is_binary(data) do
      raise ArgumentError, "the #{arg_name} must be a binary, got: #{inspect(data)}"
    end
  end
end
