defmodule Nebulex.Adapters.DiskLFU.Store do
  @moduledoc """
  Handles atomic writing and reading of cache files and their metadata to disk,
  including crash recovery, checksums, and lock-based fail-safety.
  """

  use GenServer

  import Nebulex.Utils, only: [camelize_and_concat: 1]

  alias Nebulex.Adapters.DiskLFU.Meta

  # Internal state
  defstruct cache_name: nil, cache_dir: nil, meta_table: nil

  ## API

  @doc """
  Starts the store server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Writes the given binary to disk.
  """
  @spec write_to_disk(atom(), String.t(), String.t(), binary(), keyword()) ::
          {:ok, Meta.t()} | {:error, any()}
  def write_to_disk(meta_table, cache_dir, key, binary, opts \\ []) do
    # Build the base path
    {base_path, hash_key} = build_path(cache_dir, key)

    # Build the paths for the given key
    cache_tmp = base_path <> ".cache.tmp"
    meta_tmp = base_path <> ".meta.tmp"
    cache_final = base_path <> ".cache"
    meta_final = base_path <> ".meta"

    # Write the binary to disk atomically
    with_lock(base_path, Keyword.get(opts, :retries, :infinity), fn ->
      # Get the modes to write the binary to disk
      modes = Keyword.get(opts, :modes, [])

      # Build the metadata
      meta = Meta.new(base_path, binary)
      encoded_meta = Meta.encode(meta)

      # Write the binary to disk
      with :ok <- File.write(cache_tmp, binary, modes),
           _ignore = update_stack(base_path, cache_tmp),
           :ok <- File.write(meta_tmp, encoded_meta),
           _ignore = update_stack(base_path, meta_tmp),
           :ok = flush_to_disk(cache_tmp),
           :ok = flush_to_disk(meta_tmp),
           :ok <- File.rename(cache_tmp, cache_final),
           _ignore = update_stack(base_path, cache_final),
           :ok <- File.rename(meta_tmp, meta_final) do
        # Update the meta table
        true = :ets.insert(meta_table, {hash_key, meta})

        {:ok, meta}
      else
        error ->
          # Clean up written files
          _ignore = maybe_rollback_write(base_path)

          error
      end
    end)
  end

  @doc """
  Reads the binary from disk.
  """
  @spec read_from_disk(atom(), String.t()) :: {:ok, {Meta.t(), binary()}} | {:error, any()}
  def read_from_disk(meta_table, key, retries \\ :infinity) do
    # Get the hash for the key
    hash_key = hash_key(key)

    with {:ok, %Meta{base_path: path} = meta} <- do_fetch_meta(meta_table, hash_key) do
      with_lock(path, retries, fn ->
        # Build the paths for the given key
        meta_tmp = path <> ".meta.tmp"
        meta_final = path <> ".meta"

        # Read the binary from disk and write the metadata to disk atomically
        with {:ok, binary} <- File.read(path <> ".cache"),
             meta = Meta.update_access_count(meta),
             :ok <- File.write(meta_tmp, Meta.encode(meta)),
             :ok = flush_to_disk(meta_tmp),
             :ok <- File.rename(meta_tmp, meta_final) do
          # Update the meta table
          true = :ets.insert(meta_table, {hash_key, meta})

          {:ok, {meta, binary}}
        end
      end)
    end
  end

  @doc """
  Deletes the binary from disk.
  """
  @spec delete_from_disk(atom(), String.t()) :: :ok | {:error, any()}
  def delete_from_disk(meta_table, key, retries \\ :infinity) do
    # Get the hash for the key
    hash_key = hash_key(key)

    # Check if the key exists in the meta table
    with {:ok, %Meta{base_path: path}} <- do_fetch_meta(meta_table, hash_key) do
      # Delete the metadata and binary atomically
      with_lock(path, retries, fn ->
        with :ok <- safe_rm(path <> ".meta"),
             :ok <- safe_rm(path <> ".cache") do
          # Delete the key from the meta table
          true = :ets.delete(meta_table, hash_key)

          :ok
        end
      end)
    end
  end

  @doc """
  Pops the binary from disk.
  """
  @spec pop_from_disk(atom(), String.t()) :: {:ok, {Meta.t(), binary()}} | {:error, any()}
  def pop_from_disk(meta_table, key, retries \\ :infinity) do
    # Get the hash for the key
    hash_key = hash_key(key)

    # Check if the key exists in the meta table
    with {:ok, %Meta{base_path: path} = meta} <- do_fetch_meta(meta_table, hash_key) do
      # Delete the metadata and binary atomically
      with_lock(path, retries, fn ->
        with {:ok, binary} <- File.read(path <> ".cache"),
             :ok <- safe_rm(path <> ".meta"),
             :ok <- safe_rm(path <> ".cache") do
          # Delete the key from the meta table
          true = :ets.delete(meta_table, hash_key)

          {:ok, {meta, binary}}
        end
      end)
    end
  end

  @doc """
  Checks if the key exists in the meta table.
  """
  @spec exists?(atom(), String.t()) :: boolean()
  def exists?(meta_table, key) do
    case fetch_meta(meta_table, key) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Fetches the meta for the given key.
  """
  @spec fetch_meta(atom(), String.t()) :: {:ok, Meta.t()} | {:error, :not_found}
  def fetch_meta(meta_table, key) do
    do_fetch_meta(meta_table, hash_key(key))
  end

  # @doc """
  # Deletes all the entries from disk.
  # """
  # @spec delete_all_from_disk(atom() | pid()) :: :ok | {:error, any()}
  # def delete_all_from_disk(server) do
  #   GenServer.call(server, :delete_all)
  # end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    # Get required options
    cache_name = Keyword.fetch!(opts, :cache_name)
    cache_dir = Keyword.fetch!(opts, :cache_dir)

    # Create the cache directory if it doesn't exist
    :ok = File.mkdir_p!(cache_dir)

    # Create the meta table for the cache
    meta_table = create_meta_table(cache_name)

    # Create the state for the store
    state = %__MODULE__{cache_name: cache_name, cache_dir: cache_dir, meta_table: meta_table}

    # Load the cache metadata from disk
    :ok = load_cache_metadata(state)

    # Return the state
    {:ok, state}
  end

  # @impl true
  # def handle_call(
  #       :delete_all,
  #       _from,
  #       %__MODULE__{cache_dir: cache_dir, meta_table: meta_table} = state
  #     ) do
  #   # Fix the meta table
  #   _ignore = :ets.safe_fixtable(meta_table, true)

  #   # Cleanup all the entries in the meta table
  #   :ok = cleanup_all(meta_table, cache_dir, :ets.first(meta_table))

  #   # Unfix the meta table
  #   _ignore = :ets.safe_fixtable(meta_table, false)

  #   # Return the state
  #   {:reply, :ok, state}
  # end

  ## Private functions

  defp create_meta_table(name) do
    [name, "Meta"]
    |> camelize_and_concat()
    |> :ets.new([
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])
  end

  defp with_lock(key, retries, fun) do
    with :aborted <- :global.trans({{__MODULE__, key}, self()}, fun, [node()], retries) do
      {:error, :lock_timeout}
    end
  end

  defp do_fetch_meta(meta_table, hash_key) do
    case :ets.lookup(meta_table, hash_key) do
      [{^hash_key, meta}] -> {:ok, meta}
      [] -> {:error, :not_found}
    end
  end

  defp load_cache_metadata(%__MODULE__{cache_dir: cache_dir, meta_table: meta_table}) do
    cache_dir
    |> tap(&cleanup_temp_files/1)
    |> Path.join("*.meta")
    |> Path.wildcard()
    |> Enum.reduce([], fn filename, acc ->
      case extract_meta_from_filename(filename) do
        {:ok, meta} ->
          [{extract_key_from_filename(filename), meta} | acc]

        _error ->
          acc
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> then(fn entries ->
      true = :ets.insert(meta_table, entries)

      :ok
    end)
  end

  defp cleanup_temp_files(cache_dir) do
    cache_dir
    |> Path.join("*.{tmp,lock}")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp extract_key_from_filename(filename) do
    Path.basename(filename, ".meta")
  end

  defp extract_meta_from_filename(filename) do
    with {:ok, bin} <- File.read(filename) do
      Meta.decode(bin)
    end
  end

  defp build_path(cache_dir, key) do
    hash_key = hash_key(key)

    [cache_dir, hash_key]
    |> Path.join()
    |> Kernel.<>(Path.extname(key))
    |> then(&{&1, hash_key})
  end

  defp hash_key(key) do
    :sha256
    |> :crypto.hash(key)
    |> Base.encode16()
  end

  defp flush_to_disk(path) do
    with {:ok, fd} <- File.open(path, [:raw, :read]) do
      :file.sync(fd)
      File.close(fd)
    end

    :ok
  end

  defp update_stack(key, value) do
    case Process.get({:lock, key}) do
      nil -> Process.put({:lock, key}, [value])
      stack -> Process.put({:lock, key}, [value | stack])
    end
  end

  defp maybe_rollback_write(base_path) do
    with [_ | _] = paths <- Process.get({:lock, base_path}) do
      Enum.each(paths, &File.rm/1)
    end
  after
    Process.delete({:lock, base_path})
  end

  defp safe_rm(path) do
    with {:error, :enoent} <- File.rm(path) do
      :ok
    end
  end

  # defp cleanup_all(_meta_table, _cache_dir, :"$end_of_table") do
  #   :ok
  # end

  # defp cleanup_all(meta_table, cache_dir, key) do
  #   _ignore = delete_from_disk(meta_table, key)

  #   cleanup_all(meta_table, cache_dir, :ets.next(meta_table, key))
  # end
end
