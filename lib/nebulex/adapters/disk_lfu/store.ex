defmodule Nebulex.Adapters.DiskLFU.Store do
  # Handles atomic writing and reading of cache files and their metadata to disk,
  # including crash recovery, checksums, and lock-based fail-safety.
  @moduledoc false

  use GenServer

  import Nebulex.Adapters.DiskLFU.Helpers
  import Nebulex.Time, only: [now: 0]
  import Nebulex.Utils, only: [camelize_and_concat: 1]

  alias Nebulex.Adapters.DiskLFU.Meta
  alias Nebulex.Telemetry

  ## Meta definition

  require Record

  # Record for the entry meta
  Record.defrecord(:meta,
    key: nil,
    raw_key: nil,
    checksum: nil,
    size_bytes: nil,
    access_count: 0,
    inserted_at: nil,
    last_accessed_at: nil,
    expires_at: :infinity,
    metadata: %{}
  )

  @typedoc "Metadata for the entry in the cache."
  @type meta() ::
          record(:meta,
            key: String.t(),
            raw_key: String.t(),
            checksum: binary(),
            size_bytes: non_neg_integer(),
            access_count: non_neg_integer(),
            inserted_at: non_neg_integer(),
            last_accessed_at: non_neg_integer(),
            expires_at: timeout(),
            metadata: map()
          )

  @typedoc "Proxy type for the counter reference for the cache."
  @type counter_ref() :: :counters.counters_ref()

  @typedoc "Proxy type for the adapter meta."
  @type adapter_meta() :: Nebulex.Adapter.adapter_meta()

  ## Internals

  # Internal state
  defstruct cache_name: nil,
            cache_path: nil,
            meta_table: nil,
            meta_sync_timeout: nil,
            meta_sync_timer_ref: nil,
            telemetry_prefix: nil

  # Default lock retries
  @default_lock_retries 10

  ## API

  @doc """
  Starts the store server.
  """
  @spec start_link(adapter_meta()) :: GenServer.on_start()
  def start_link(adapter_meta) do
    GenServer.start_link(__MODULE__, adapter_meta)
  end

  @doc """
  Writes the given binary to disk.
  """
  @spec write_to_disk(adapter_meta(), String.t(), binary(), keyword()) ::
          {:ok, meta()} | {:error, any()}
  def write_to_disk(
        %{
          meta_table: meta_table,
          bytes_counter: counter_ref,
          cache_path: cache_path
        } = adapter_meta,
        key,
        binary,
        opts
      ) do
    # Build the base path
    {base_path, hash_key} = build_path(cache_path, key)

    # Build the paths for the given key
    cache_tmp = base_path <> ".cache.tmp"
    meta_tmp = base_path <> ".meta.tmp"
    cache_final = base_path <> ".cache"
    meta_final = base_path <> ".meta"

    # Get the retries
    retries = Keyword.fetch!(opts, :retries)

    # Write the binary to disk atomically
    with_lock(hash_key, retries, fn ->
      # Get the cache options
      ttl = Keyword.fetch!(opts, :ttl)
      metadata = Keyword.fetch!(opts, :metadata)

      # Build the metadata
      meta =
        new_meta(binary,
          key: hash_key,
          raw_key: key,
          expires_at: expires_at(ttl),
          metadata: metadata
        )

      # Get the current size of the binary (if any)
      current_size = get_current_size_bytes(meta_table, hash_key)

      # New size of the binary
      new_size = byte_size(binary)

      # Write the binary to disk
      with :ok <- maybe_trigger_eviction(adapter_meta, current_size, new_size),
           :ok <- File.write(cache_tmp, binary, [:binary, :write]),
           _ignore = update_stack(base_path, cache_tmp),
           :ok <- File.write(meta_tmp, encode_meta(meta)),
           _ignore = update_stack(base_path, meta_tmp),
           :ok = flush_to_disk(cache_tmp),
           :ok = flush_to_disk(meta_tmp),
           :ok <- File.rename(cache_tmp, cache_final),
           _ignore = update_stack(base_path, cache_final),
           :ok <- File.rename(meta_tmp, meta_final) do
        # Update the bytes counter
        :ok = :counters.add(counter_ref, 1, new_size - current_size)

        # Update the meta table
        true = :ets.insert(meta_table, meta)

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
  @spec read_from_disk(adapter_meta(), String.t(), timeout()) ::
          {:ok, {binary(), Meta.t()}} | {:error, any()}
  def read_from_disk(
        %{meta_table: meta_table, cache_path: cache_path, bytes_counter: counter_ref},
        key,
        retries
      ) do
    # Get the hash for the key and the path for the cache
    hash_key = hash_key(key)
    path = cache_key_path(cache_path, hash_key)

    # Read the binary from disk and update the metadata
    # TODO: The metadata is persisted to disk asynchronously periodically
    with_meta(
      meta_table,
      counter_ref,
      hash_key,
      path,
      retries,
      false,
      fn meta(access_count: count) = meta ->
        with {:ok, binary} <- File.read(path <> ".cache") do
          # Update the metadata
          count = count + 1
          now = now()
          meta = new_meta(meta, access_count: count, last_accessed_at: now)

          # Update the meta table
          _ignore =
            :ets.update_element(meta_table, hash_key, [
              {meta(:access_count) + 1, count},
              {meta(:last_accessed_at), now}
            ])

          {:ok, {binary, export_meta(meta)}}
        end
      end
    )
  end

  @doc """
  Deletes the binary from disk.
  """
  @spec delete_from_disk(adapter_meta(), String.t(), timeout()) ::
          :ok | {:error, any()}
  def delete_from_disk(
        %{meta_table: meta_table, bytes_counter: counter_ref, cache_path: cache_path},
        key,
        retries
      ) do
    # Get the hash for the key and the path for the cache
    hash_key = hash_key(key)
    path = cache_key_path(cache_path, hash_key)

    with_meta(meta_table, counter_ref, hash_key, path, retries, fn meta(size_bytes: bin_size) ->
      with :ok <- safe_remove(meta_table, hash_key, path) do
        # Update the max bytes counter
        :ok = :counters.sub(counter_ref, 1, bin_size)
      end
    end)
  end

  @doc """
  Pops the binary from disk.
  """
  @spec pop_from_disk(adapter_meta(), String.t(), timeout()) ::
          {:ok, {binary(), Meta.t()}} | {:error, any()}
  def pop_from_disk(
        %{meta_table: meta_table, bytes_counter: counter_ref, cache_path: cache_path},
        key,
        retries
      ) do
    # Get the hash for the key and the path for the cache
    hash_key = hash_key(key)
    path = cache_key_path(cache_path, hash_key)

    with_meta(
      meta_table,
      counter_ref,
      hash_key,
      path,
      retries,
      fn meta(size_bytes: bin_size) = meta ->
        with {:ok, binary} <- File.read(path <> ".cache"),
             :ok <- safe_remove(meta_table, hash_key, path) do
          # Update the max bytes counter
          :ok = :counters.sub(counter_ref, 1, bin_size)

          {:ok, {binary, export_meta(meta)}}
        end
      end
    )
  end

  @doc """
  Fetches the meta for the given key.
  """
  @spec fetch_meta(adapter_meta(), String.t(), timeout()) ::
          {:ok, Meta.t()} | {:error, :not_found}
  def fetch_meta(
        %{meta_table: meta_table, cache_path: cache_path, bytes_counter: counter_ref},
        key,
        retries
      ) do
    # Get the hash for the key and the path for the cache
    hash_key = hash_key(key)
    path = cache_key_path(cache_path, hash_key)

    with_meta(meta_table, counter_ref, hash_key, path, retries, &{:ok, export_meta(&1)})
  end

  @doc """
  Pops the meta for the given key.
  """
  @spec pop_meta(adapter_meta(), String.t(), timeout()) ::
          {:ok, Meta.t()} | {:error, any()}
  def pop_meta(
        %{meta_table: meta_table, cache_path: cache_path, bytes_counter: counter_ref},
        key,
        retries
      ) do
    # Get the hash for the key and the path for the cache
    hash_key = hash_key(key)
    path = cache_key_path(cache_path, hash_key)

    with_meta(
      meta_table,
      counter_ref,
      hash_key,
      path,
      retries,
      fn meta(size_bytes: bin_size) = meta ->
        with :ok <- safe_remove(meta_table, hash_key, path) do
          # Update the max bytes counter
          :ok = :counters.sub(counter_ref, 1, bin_size)

          {:ok, export_meta(meta)}
        end
      end
    )
  end

  @doc """
  Updates the meta for the given key.
  """
  @spec update_meta(adapter_meta(), String.t(), timeout(), (Meta.t() -> Meta.t())) ::
          :ok | {:error, any()}
  def update_meta(
        %{meta_table: meta_table, cache_path: cache_path, bytes_counter: counter_ref},
        key,
        retries,
        fun
      ) do
    # Get the hash for the key and the path for the cache
    hash_key = hash_key(key)
    path = cache_key_path(cache_path, hash_key)

    with_meta(meta_table, counter_ref, hash_key, path, retries, fn meta(key: ^hash_key) = meta ->
      # Build the metadata path
      meta_tmp = path <> ".meta.tmp"
      meta_final = path <> ".meta"

      # Write the metadata to disk atomically
      with {:ok, _encoded_meta} <- File.read(meta_final),
           meta = meta |> export_meta() |> fun.() |> import_meta(),
           meta = meta(meta, key: hash_key),
           :ok <- File.write(meta_tmp, encode_meta(meta)),
           :ok <- File.rename(meta_tmp, meta_final) do
        # Flush the metadata to disk
        :ok = flush_to_disk(meta_final)

        # Update the meta table
        true = :ets.insert(meta_table, meta)

        :ok
      end
    end)
  end

  @doc """
  Counts all the entries in the meta table.
  """
  @spec count_all(atom()) :: non_neg_integer()
  def count_all(meta_table) do
    # Get the count of all the entries in the meta table
    :ets.info(meta_table, :size)
  end

  @doc """
  Deletes all the entries from disk.
  """
  @spec delete_all_from_disk(atom(), String.t()) :: non_neg_integer()
  def delete_all_from_disk(meta_table, cache_path) do
    # Fix the meta table
    _ignore = :ets.safe_fixtable(meta_table, true)

    # Cleanup all the entries in the meta table
    count = cleanup_all(meta_table, cache_path, :ets.first(meta_table))

    # Unfix the meta table
    _ignore = :ets.safe_fixtable(meta_table, false)

    count
  end

  @doc """
  Gets all the keys from the meta table.
  """
  @spec get_all_keys(atom()) :: [String.t()]
  def get_all_keys(meta_table) do
    :ets.select(meta_table, meta_match_spec())
  end

  ## GenServer callbacks

  @impl true
  def init(%{
        name: cache_name,
        cache_path: cache_path,
        metadata_persistence_timeout: meta_sync_timeout,
        telemetry_prefix: telemetry_prefix
      }) do
    # Trap exits to handle crashes
    Process.flag(:trap_exit, true)

    # Create the cache directory if it doesn't exist
    :ok = File.mkdir_p!(cache_path)

    # Create the meta table for the cache
    meta_table = create_meta_table(cache_name)

    # Create the state for the store
    state = %__MODULE__{
      cache_name: cache_name,
      cache_path: cache_path,
      meta_table: meta_table,
      meta_sync_timeout: meta_sync_timeout,
      telemetry_prefix: telemetry_prefix
    }

    # Load the cache metadata from disk
    :ok = load_cache_metadata(state)

    # Return the state
    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, %__MODULE__{meta_sync_timeout: meta_sync_timeout} = state) do
    # Reset the metadata sync timer
    meta_sync_ref = reset_timer(meta_sync_timeout)

    {:noreply, %{state | meta_sync_timer_ref: meta_sync_ref}}
  end

  @impl true
  def handle_info(message, state)

  def handle_info(
        :meta_sync,
        %__MODULE__{
          meta_table: meta_table,
          cache_path: cache_path,
          meta_sync_timeout: meta_sync_timeout,
          meta_sync_timer_ref: meta_sync_ref,
          telemetry_prefix: telemetry_prefix
        } = state
      ) do
    # Persist the metadata to disk
    _count = persist_meta(meta_table, cache_path, telemetry_prefix)

    # Reset the metadata sync timer
    meta_sync_ref = reset_timer(meta_sync_timeout, meta_sync_ref)

    # Return the state
    {:noreply, %{state | meta_sync_timer_ref: meta_sync_ref}}
  end

  @impl true
  def terminate(_reason, %__MODULE__{
        meta_table: meta_table,
        cache_path: cache_path,
        telemetry_prefix: telemetry_prefix
      }) do
    # Persist the metadata to disk
    persist_meta(meta_table, cache_path, telemetry_prefix)
  end

  ## Private functions

  defp create_meta_table(name) do
    [name, "Meta"]
    |> camelize_and_concat()
    |> :ets.new([
      :set,
      :public,
      :named_table,
      keypos: meta(:key) + 1,
      read_concurrency: true
    ])
  end

  defp reset_timer(time, ref \\ nil, event \\ :meta_sync)

  defp reset_timer(nil, _, _) do
    nil
  end

  defp reset_timer(time, ref, event) do
    _ = if ref, do: Process.cancel_timer(ref)

    Process.send_after(self(), event, time)
  end

  defp persist_meta(meta_table, cache_path, telemetry_prefix) do
    # Define the persist function
    persist_fun = fn meta(key: hash_key) = meta, acc ->
      fun = fn ->
        path = cache_key_path(cache_path, hash_key)
        meta_tmp = path <> ".meta.tmp"
        meta_final = path <> ".meta"

        with :ok <- File.write(meta_tmp, encode_meta(meta)),
             :ok <- File.rename(meta_tmp, meta_final) do
          acc + 1
        end
      end

      with {:error, :lock_timeout} <- with_lock(hash_key, @default_lock_retries, fun) do
        # If a timeout occurs, skip the file and return the accumulator
        acc
      end
    end

    # Define the telemetry metadata
    telemetry_metadata = %{
      store_pid: self(),
      count: 0
    }

    # Wrap the persist function in a telemetry span
    Telemetry.span(telemetry_prefix ++ [:disk_lfu, :persist_meta], telemetry_metadata, fn ->
      # Persist the metadata to disk
      count = :ets.foldl(persist_fun, 0, meta_table)

      # Update the telemetry metadata with the count
      {count, %{telemetry_metadata | count: count}}
    end)
  end

  defp with_meta(meta_table, counter_ref, hash_key, path, retries, lock? \\ true, fun) do
    now = now()

    case :ets.lookup(meta_table, hash_key) do
      [meta(key: ^hash_key, expires_at: expires_at, size_bytes: bin_size)]
      when is_integer(expires_at) and expires_at <= now ->
        with_lock(hash_key, retries, fn ->
          with :ok <- safe_remove(meta_table, hash_key, path) do
            # Update the max bytes counter
            :ok = :counters.sub(counter_ref, 1, bin_size)

            {:error, :expired}
          end
        end)

      [meta(key: ^hash_key) = meta] when lock? == true ->
        with_lock(hash_key, retries, fn -> fun.(meta) end)

      [meta(key: ^hash_key) = meta] ->
        fun.(meta)

      [] ->
        {:error, :not_found}
    end
  end

  defp with_lock(key, retries, fun) do
    with :aborted <- :global.trans({{__MODULE__, key}, self()}, fun, [node()], retries) do
      {:error, :lock_timeout}
    end
  end

  defp safe_remove(meta_table, hash_key, path) do
    # Remove the metadata and binary from disk
    with :ok <- safe_rm(path <> ".meta"),
         :ok <- safe_rm(path <> ".cache") do
      # Delete the key from the meta table
      true = :ets.delete(meta_table, hash_key)

      :ok
    end
  end

  defp safe_rm(path) do
    with {:error, :enoent} <- File.rm(path) do
      :ok
    end
  end

  defp load_cache_metadata(%__MODULE__{cache_path: cache_path, meta_table: meta_table}) do
    cache_path
    |> tap(&cleanup_temp_files/1)
    |> Path.join("*.meta")
    |> Path.wildcard()
    |> Enum.reduce([], fn filename, acc ->
      case extract_meta_from_filename(filename) do
        {:ok, meta} ->
          [meta | acc]

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

  defp cleanup_temp_files(cache_path) do
    cache_path
    |> Path.join("*.{tmp,lock}")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp extract_meta_from_filename(filename) do
    with {:ok, bin} <- File.read(filename) do
      decode_meta(bin)
    end
  end

  defp build_path(cache_path, key) do
    hash_key = hash_key(key)

    {cache_key_path(cache_path, hash_key), hash_key}
  end

  defp cache_key_path(cache_path, hash_key) do
    Path.join([cache_path, hash_key])
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

  defp cleanup_all(meta_table, cache_path, hash_key) do
    cleanup_all(meta_table, cache_path, hash_key, 0)
  end

  defp cleanup_all(_meta_table, _cache_path, :"$end_of_table", count) do
    count
  end

  defp cleanup_all(meta_table, cache_path, hash_key, count) do
    with_lock(hash_key, @default_lock_retries, fn ->
      path = cache_key_path(cache_path, hash_key)

      safe_remove(meta_table, hash_key, path)
    end)

    cleanup_all(meta_table, cache_path, :ets.next(meta_table, hash_key), count + 1)
  end

  defp get_current_size_bytes(meta_table, key) do
    case :ets.lookup(meta_table, key) do
      [meta(key: ^key, size_bytes: current_size)] -> current_size
      [] -> 0
    end
  end

  defp maybe_trigger_eviction(
         %{
           bytes_counter: counter_ref,
           max_bytes: max_bytes
         } = adapter_meta,
         current_size,
         new_size
       ) do
    # Get base metrics
    bytes_count = :counters.get(counter_ref, 1)
    diff_size = new_size - current_size

    # Check eviction conditions
    cond do
      # If the new size exceeds the max bytes, return an error
      new_size > max_bytes ->
        {:error, :max_bytes_exceeded}

      # If the new size exceeds the max bytes, run the eviction process
      bytes_count + diff_size > max_bytes ->
        # Run the eviction process
        :ok = run_eviction(adapter_meta, diff_size, bytes_count)

        # Continue with the eviction process
        maybe_trigger_eviction(adapter_meta, current_size, new_size)

      # Skip the eviction process
      true ->
        :ok
    end
  end

  defp run_eviction(
         %{
           telemetry_prefix: telemetry_prefix,
           cache_path: cache_path,
           meta_table: meta_table,
           bytes_counter: counter_ref,
           max_bytes: max_bytes,
           eviction_victim_sample_size: select_limit,
           eviction_victim_limit: victims_limit
         } = adapter_meta,
         diff_size,
         bytes_count
       ) do
    # Define the eviction function
    eviction_fun = fn ->
      # We need to check again if the new size plus the current size exceeds
      # the max bytes because the counter could have been updated by another
      # process while we were waiting for the lock
      if :counters.get(counter_ref, 1) + diff_size > max_bytes do
        meta_table
        # Select the expired victims first, then the least recently used victims
        |> select_eviction_victims(select_limit)
        # Sorts the victims according to Erlang's term ordering
        # The term is: {access_count, last_accessed_at, key}
        |> Enum.sort()
        # Take the victims limit
        |> Enum.take(victims_limit)
        # Delete the victims from disk
        |> Enum.each(&delete_from_disk(adapter_meta, elem(&1, 2), 10))
      end

      # Acknoledge the eviction
      :ok
    end

    # Define the telemetry metadata
    telemetry_metadata = %{
      stored_bytes: bytes_count,
      max_bytes: max_bytes,
      victim_sample_size: select_limit,
      victims_limit: victims_limit,
      result: nil
    }

    # Wrap the eviction function in a telemetry span
    Telemetry.span(telemetry_prefix ++ [:disk_lfu, :eviction], telemetry_metadata, fn ->
      # Locking at the cache directory level is required to avoid race conditions
      # when multiple processes are trying to evict at the same time
      result = with_lock(cache_path, :infinity, eviction_fun)

      # Update the telemetry metadata with the result and the new stored bytes
      telemetry_metadata = %{
        telemetry_metadata
        | result: result,
          stored_bytes: :counters.get(counter_ref, 1)
      }

      # Return the result and the telemetry metadata
      {result, telemetry_metadata}
    end)
  end

  defp select_eviction_victims(meta_table, select_limit) do
    expired_match_spec =
      meta_match_spec(
        [{:not, {:orelse, {:"=:=", :"$8", :infinity}, {:<, now(), :"$8"}}}],
        {{:"$5", :"$8", :"$2"}}
      )

    case :ets.select(meta_table, expired_match_spec, select_limit) do
      {[_ | _] = victims, _cont} ->
        victims

      _else ->
        case :ets.select(meta_table, meta_match_spec([], {{:"$5", :"$7", :"$2"}}), select_limit) do
          {victims, _cont} ->
            victims

          # coveralls-ignore-start
          _else ->
            []
            # coveralls-ignore-stop
        end
    end
  end

  ## Internal meta functions

  defp new_meta(fields) do
    new_meta(meta(), fields)
  end

  defp new_meta(meta() = meta, fields) when is_list(fields) or is_map(fields) do
    Enum.reduce(fields, meta, fn
      {:key, value}, meta -> meta(meta, key: value)
      {:raw_key, value}, meta -> meta(meta, raw_key: value)
      {:checksum, value}, meta -> meta(meta, checksum: value)
      {:size_bytes, value}, meta -> meta(meta, size_bytes: value)
      {:access_count, value}, meta -> meta(meta, access_count: value)
      {:inserted_at, value}, meta -> meta(meta, inserted_at: value)
      {:last_accessed_at, value}, meta -> meta(meta, last_accessed_at: value)
      {:expires_at, value}, meta -> meta(meta, expires_at: value)
      {:metadata, value}, meta -> meta(meta, metadata: value)
    end)
  end

  defp new_meta(data, fields) when is_binary(data) and is_list(fields) do
    now = now()

    [
      checksum: checksum(data),
      size_bytes: byte_size(data),
      inserted_at: now,
      last_accessed_at: now
    ]
    |> Keyword.merge(fields)
    |> new_meta()
  end

  defp encode_meta(meta() = meta) do
    :erlang.term_to_binary(meta)
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_meta(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary) do
      meta() = meta ->
        {:ok, meta}

      _error ->
        :error
    end
  end

  defp export_meta(
         meta(
           raw_key: raw_key,
           checksum: checksum,
           size_bytes: size_bytes,
           access_count: access_count,
           inserted_at: inserted_at,
           last_accessed_at: last_accessed_at,
           expires_at: expires_at,
           metadata: metadata
         )
       ) do
    %Meta{
      key: raw_key,
      checksum: checksum,
      size_bytes: size_bytes,
      access_count: access_count,
      inserted_at: inserted_at,
      last_accessed_at: last_accessed_at,
      expires_at: expires_at,
      metadata: metadata
    }
  end

  defp import_meta(%Meta{
         key: key,
         checksum: checksum,
         size_bytes: size_bytes,
         access_count: access_count,
         inserted_at: inserted_at,
         last_accessed_at: last_accessed_at,
         expires_at: expires_at,
         metadata: metadata
       }) do
    meta(
      raw_key: key,
      checksum: checksum,
      size_bytes: size_bytes,
      access_count: access_count,
      inserted_at: inserted_at,
      last_accessed_at: last_accessed_at,
      expires_at: expires_at,
      metadata: metadata
    )
  end

  defp meta_match_spec(conds \\ [], return \\ :"$2") do
    [
      {meta(
         key: :"$1",
         raw_key: :"$2",
         checksum: :"$3",
         size_bytes: :"$4",
         access_count: :"$5",
         inserted_at: :"$6",
         last_accessed_at: :"$7",
         expires_at: :"$8",
         metadata: :"$9"
       ), conds, [return]}
    ]
  end
end
