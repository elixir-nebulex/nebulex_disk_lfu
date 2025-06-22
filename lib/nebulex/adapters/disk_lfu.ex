defmodule Nebulex.Adapters.DiskLFU do
  @moduledoc """
  A Nebulex adapter for a disk-based LFU cache.
  """

  # Provide Cache Implementation
  @behaviour Nebulex.Adapter
  @behaviour Nebulex.Adapter.KV

  import Nebulex.Adapter
  import Nebulex.Utils

  alias __MODULE__.{Options, Store}

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

    adapter_meta = %{
      name: name,
      base_dir: base_dir,
      cache_dir: cache_dir,
      meta_tab: camelize_and_concat([name, Meta])
    }

    child_spec =
      Supervisor.child_spec(
        {Store, cache_name: name, cache_dir: cache_dir},
        id: {__MODULE__, camelize_and_concat([name, Store])}
      )

    {:ok, child_spec, adapter_meta}
  end

  ## Nebulex.Adapter.KV

  @impl true
  def fetch(%{meta_tab: meta_tab}, key, opts) do
    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    with {:ok, {_meta, binary}} <- Store.read_from_disk(meta_tab, key, retries) do
      {:ok, binary}
    end
    |> handle_result(key)
  end

  @impl true
  def put(
        %{meta_tab: meta_tab, cache_dir: cache_dir},
        key,
        value,
        _on_write,
        _ttl,
        _keep_ttl?,
        opts
      ) do
    opts = Options.validate_common_runtime_opts!(opts)

    assert_binary(key, "key")
    assert_binary(value, "value")

    with {:ok, _} <- Store.write_to_disk(meta_tab, cache_dir, key, value, opts) do
      :ok
    end
    |> handle_result()
  end

  @impl true
  def put_all(%{meta_tab: meta_tab, cache_dir: cache_dir}, entries, _on_write, _ttl, opts) do
    opts = Options.validate_common_runtime_opts!(opts)

    entries
    |> Stream.map(fn {key, value} ->
      assert_binary(key, "key")
      assert_binary(value, "value")

      {key, value}
    end)
    |> Enum.reduce_while(:ok, fn {key, value}, acc ->
      case Store.write_to_disk(meta_tab, cache_dir, key, value, opts) do
        {:ok, _} -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> handle_result()
  end

  @impl true
  def delete(%{meta_tab: meta_tab}, key, opts) do
    opts = Options.validate_common_runtime_opts!(opts)

    Store.delete_from_disk(meta_tab, key, Keyword.fetch!(opts, :retries))
    |> handle_result(key)
  end

  @impl true
  def take(%{meta_tab: meta_tab}, key, opts) do
    opts = Options.validate_common_runtime_opts!(opts)
    retries = Keyword.fetch!(opts, :retries)

    with {:ok, {_meta, binary}} <- Store.pop_from_disk(meta_tab, key, retries) do
      {:ok, binary}
    end
    |> handle_result(key)
  end

  @impl true
  def has_key?(%{meta_tab: meta_tab}, key, _opts) do
    {:ok, Store.exists?(meta_tab, key)}
  end

  @impl true
  def ttl(%{meta_tab: meta_tab}, key, _opts) do
    with {:ok, _} <- Store.fetch_meta(meta_tab, key) do
      {:ok, :infinity}
    end
    |> handle_result(key)
  end

  @impl true
  def expire(%{meta_tab: meta_tab}, key, _ttl, _opts) do
    {:ok, Store.exists?(meta_tab, key)}
  end

  @impl true
  def touch(%{meta_tab: meta_tab}, key, _opts) do
    {:ok, Store.exists?(meta_tab, key)}
  end

  @impl true
  def update_counter(_adapter_meta, _key, _amount, _default, _ttl, _opts) do
    {:ok, 1}
  end

  ## Private functions

  defp handle_result(result, ctx \\ :"$no_ctx")

  defp handle_result({:error, :not_found}, key) do
    wrap_error Nebulex.KeyError, key: key, reason: :not_found
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

  defp assert_binary(data, arg_name) do
    unless is_binary(data) do
      raise ArgumentError, "the #{arg_name} must be a binary, got: #{inspect(data)}"
    end
  end
end
