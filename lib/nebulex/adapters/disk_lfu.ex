defmodule Nebulex.Adapters.DiskLFU do
  @moduledoc """
  A Nebulex adapter for a disk-based LFU cache.

  This adapter is ideally for those use cases when you want to use a disk-based
  cache storage to optimize expensive operations. For example, you have an
  application that downloads large files from S3 to process them, and those
  files are reusable. In such cases, it may be cheaper reading the file from
  the local file system (ideally using SSD) rather that reading it multiple
  times from S3.

  This adapter stores the cache in a directory on the file system. It uses the
  [LFU](https://en.wikipedia.org/wiki/Least_Frequently_Used) algorithm to
  evict the least frequently used items.

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
      @spec cache_dir(atom()) :: String.t()
      def cache_dir(name \\ __MODULE__) do
        name
        |> lookup_meta()
        |> Map.fetch!(:cache_dir)
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
    {base_dir, opts} = Keyword.pop!(opts, :base_dir)
    name = opts[:name] || cache
    cache_dir = Path.join(base_dir, to_string(name))

    # Create the adapter meta
    adapter_meta = %{
      name: name,
      base_dir: base_dir,
      cache_dir: cache_dir,
      meta_tab: camelize_and_concat([name, "Meta"])
    }

    # Create the child spec for the store
    child_spec =
      Supervisor.child_spec(
        {Store, cache_name: name, cache_dir: cache_dir},
        id: {__MODULE__, camelize_and_concat([name, Store])}
      )

    {:ok, child_spec, adapter_meta}
  end

  ## Nebulex.Adapter.KV

  @impl true
  def fetch(%{cache_dir: cache_dir, meta_tab: meta_tab}, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_read_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)
    return = Keyword.fetch!(opts, :return)

    with {:ok, {binary, %Meta{metadata: meta}}} <-
           Store.read_from_disk(meta_tab, cache_dir, key, retries) do
      handle_return(return, {binary, meta})
    end
    |> handle_result(key)
  end

  @impl true
  def put(
        %{meta_tab: meta_tab, cache_dir: cache_dir},
        key,
        value,
        _on_write,
        ttl,
        _keep_ttl?,
        opts
      ) do
    assert_binary(key, "key")
    assert_binary(value, "value")

    opts = Options.validate_write_opts!(opts)

    with {:ok, _} <- Store.write_to_disk(meta_tab, cache_dir, key, value, [ttl: ttl] ++ opts) do
      :ok
    end
    |> handle_result()
  end

  @impl true
  def put_all(%{meta_tab: meta_tab, cache_dir: cache_dir}, entries, _on_write, ttl, opts) do
    opts = Options.validate_write_opts!(opts)

    entries
    |> Stream.map(fn {key, value} ->
      assert_binary(key, "key")
      assert_binary(value, "value")

      {key, value}
    end)
    |> Enum.reduce_while(:ok, fn {key, value}, acc ->
      case Store.write_to_disk(meta_tab, cache_dir, key, value, [ttl: ttl] ++ opts) do
        {:ok, _} -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> handle_result()
  end

  @impl true
  def delete(%{meta_tab: meta_tab, cache_dir: cache_dir}, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    meta_tab
    |> Store.delete_from_disk(cache_dir, key, retries)
    |> handle_result(key)
  end

  @impl true
  def take(%{meta_tab: meta_tab, cache_dir: cache_dir}, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_read_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)
    return = Keyword.fetch!(opts, :return)

    with {:ok, {binary, %Meta{metadata: meta}}} <-
           Store.pop_from_disk(meta_tab, cache_dir, key, retries) do
      handle_return(return, {binary, meta})
    end
    |> handle_result(key)
  end

  @impl true
  def has_key?(%{meta_tab: meta_tab, cache_dir: cache_dir}, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    case Store.fetch_meta(meta_tab, cache_dir, key, retries) do
      {:ok, _} -> {:ok, true}
      {:error, reason} when reason in [:not_found, :expired] -> {:ok, false}
      {:error, _} = error -> handle_result(error)
    end
  end

  @impl true
  def ttl(%{meta_tab: meta_tab, cache_dir: cache_dir}, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    with {:ok, %Meta{expires_at: expires_at}} <-
           Store.fetch_meta(meta_tab, cache_dir, key, retries) do
      {:ok, remaining_ttl(expires_at)}
    end
    |> handle_result(key)
  end

  @impl true
  def expire(%{meta_tab: meta_tab, cache_dir: cache_dir}, key, ttl, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    Store.update_meta(
      meta_tab,
      cache_dir,
      key,
      retries,
      &%{&1 | expires_at: expires_at(ttl)}
    )
    |> case do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> handle_result(error)
    end
  end

  @impl true
  def touch(%{meta_tab: meta_tab, cache_dir: cache_dir}, key, opts) do
    assert_binary(key, "key")

    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    case Store.update_meta(meta_tab, cache_dir, key, retries, &%{&1 | last_accessed_at: now()}) do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> handle_result(error)
    end
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
        %{meta_tab: meta_tab},
        %{op: :count_all, query: {:q, nil}},
        _opts
      ) do
    {:ok, Store.count_all(meta_tab)}
  end

  def execute(
        %{meta_tab: meta_tab, cache_dir: cache_dir},
        %{op: :delete_all, query: {:q, nil}},
        _opts
      ) do
    {:ok, Store.delete_all_from_disk(meta_tab, cache_dir)}
  end

  def execute(
        %{meta_tab: meta_tab},
        %{op: :get_all, query: {:q, nil}},
        _opts
      ) do
    {:ok, Store.get_all_keys(meta_tab)}
  end

  def execute(_adapter_meta, %{op: op, query: query}, _opts) do
    # TODO: Support more queries (e.g., `{:in, [...]}`, `{:q, match_spec}`)
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

  defp assert_binary(data, arg_name) do
    unless is_binary(data) do
      raise ArgumentError, "the #{arg_name} must be a binary, got: #{inspect(data)}"
    end
  end

  defp remaining_ttl(:infinity), do: :infinity
  defp remaining_ttl(expires_at), do: expires_at - now()
end
