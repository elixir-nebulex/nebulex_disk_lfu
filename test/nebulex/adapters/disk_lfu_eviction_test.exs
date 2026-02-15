defmodule Nebulex.Adapters.DiskLFUEvictionTest do
  use ExUnit.Case, async: true

  import Mimic, only: [stub: 3, allow: 3]
  import Nebulex.Adapters.DiskLFU.TestUtils

  alias Nebulex.Adapter
  alias Nebulex.Adapters.DiskLFU.Store
  alias Nebulex.Telemetry

  defmodule DiskCache do
    use Nebulex.Cache,
      otp_app: :nebulex_disk_lfu,
      adapter: Nebulex.Adapters.DiskLFU
  end

  # Telemetry prefix for the test
  @telemetry_prefix Telemetry.default_prefix(DiskCache)

  setup do
    dir = Briefly.create!(type: :directory)

    {:ok, cache: DiskCache, dir: dir}
  end

  describe "eviction scenarios" do
    @start @telemetry_prefix ++ [:eviction, :start]
    @stop @telemetry_prefix ++ [:eviction, :stop]
    @events [@start, @stop]

    setup %{dir: dir} do
      pid =
        start_supervised!(
          {DiskCache,
           root_path: dir,
           max_bytes: 20,
           eviction_victim_limit: 2,
           metadata_persistence_timeout: nil}
        )

      {:ok, pid: pid}
    end

    test "1: data is evicted when the max bytes is reached", %{cache: cache} do
      with_telemetry_handler @events, fn ->
        :ok = cache.put("key1", "12345")
        :ok = cache.put("key2", "12345", ttl: 10)
        :ok = cache.put("key3", "12345", ttl: 50)
        :ok = cache.put("key4", "12345", ttl: 100)

        # Should increment the access count
        assert cache.get!("key1") == "12345"

        :ok = Process.sleep(20)

        # This should evict: key2, key3, key4
        :ok = cache.put("key5", "1234567890", ttl: 100)

        # Assert the telemetry events for the eviction
        assert_receive {@start, %{}, %{stored_bytes: 20}}
        assert_receive {@stop, %{}, %{result: :ok, stored_bytes: 15}}

        assert cache.get!("key1") == "12345"
        refute cache.get!("key2")
        refute cache.get!("key3")
        refute cache.get!("key4")
        assert cache.get!("key5") == "1234567890"
      end
    end

    test "2: bytes count is updated", %{cache: cache} do
      Enum.each(1..4, &cache.put("key#{&1}", "12345"))

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 20

      # This should evict 2 keys
      :ok = cache.put("key5", "1234567890")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 20

      # This should delete the key5
      :ok = cache.delete("key5")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 10

      # This should not evict any key
      :ok = cache.put("key6", "12345")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 15

      # This should delete the key6
      assert cache.take!("key6") == "12345"

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 10
    end

    test "3: multiple writes to the same key", %{cache: cache} do
      :ok = cache.put("key0", "12345")
      :ok = cache.put("key1", "12345")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 10

      :ok = cache.put("key1", "1234567890")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 15

      :ok = cache.put("key1", "123456789012345")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 20

      :ok = cache.put("key1", "12345")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 10
    end
  end

  describe "eviction corner cases" do
    setup %{dir: dir} do
      pid = start_supervised!({DiskCache, root_path: dir, max_bytes: 20, eviction_victim_limit: 2})

      {:ok, pid: pid}
    end

    test "1: the initial write size exceeds the max bytes", %{cache: cache} do
      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 0

      assert {:error, %Nebulex.Error{reason: :max_bytes_exceeded}} =
               cache.put("key1", String.duplicate("12345", 5))

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 0
    end

    test "2: the next write size exceeds the max bytes", %{cache: cache} do
      str = String.duplicate("12345", 4)
      :ok = cache.put("key1", str)

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 20

      assert {:error, %Nebulex.Error{reason: :max_bytes_exceeded}} =
               cache.put("key2", str <> "1")

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 20

      :ok = cache.put("key1", str)

      assert :counters.get(Adapter.lookup_meta(cache).bytes_counter, 1) == 20
    end
  end

  describe "metadata persistence" do
    @start @telemetry_prefix ++ [:persist_meta, :start]
    @stop @telemetry_prefix ++ [:persist_meta, :stop]
    @events [@start, @stop]

    setup %{dir: dir} do
      {:ok, pid} =
        DiskCache.start_link(
          root_path: dir,
          metadata_persistence_timeout: 500
        )

      on_exit(fn -> safe_stop(pid) end)

      {:ok, pid: pid}
    end

    test "1: metadata is persisted to disk", %{cache: cache, dir: dir} do
      with_telemetry_handler @events, fn ->
        # Write some data to the cache
        :ok = cache.put("key1", "12345")

        # Should increment the access count
        assert cache.get!("key1") == "12345"

        # Check if the metadata is updated
        assert {:ok, meta} = fetch_meta(cache, "key1")
        assert meta.access_count == 1

        # Metadata persistence should have stopped
        assert_receive {@stop, %{}, %{}}, 1000

        # Restart the cache and check if the metadata is still there
        :ok = cache.stop()
        {:ok, _pid} = cache.start_link(root_path: dir)

        # Check if the metadata is updated
        assert {:ok, meta} = fetch_meta(cache, "key1")
        assert meta.access_count == 1

        # Stop the cache
        :ok = cache.stop()
      end
    end

    test "2: fails because lock timeout", %{cache: cache, dir: dir} do
      with_telemetry_handler @events, fn ->
        # Write some data to the cache
        :ok = cache.put("key1", "12345")

        # Should increment the access count
        assert cache.get!("key1") == "12345"

        # Check if the metadata is updated
        assert {:ok, meta} = fetch_meta(cache, "key1")
        assert meta.access_count == 1

        # Metadata persistence should start
        assert_receive {@start, %{}, %{store_pid: store_pid}}, 1000

        # Metadata persistence should stop
        assert_receive {@stop, %{}, %{}}, 1000

        # Simulate a lock timeout
        File
        |> stub(:write, fn _, _ -> {:error, :lock_timeout} end)
        |> allow(self(), store_pid)

        # Should increment the access count
        assert cache.get!("key1") == "12345"

        # Check if the metadata is updated
        assert {:ok, meta} = fetch_meta(cache, "key1")
        assert meta.access_count == 2

        # Metadata persistence should start
        assert_receive {@start, %{}, %{}}, 1000

        # Metadata persistence should stop
        assert_receive {@stop, %{}, %{}}, 1000

        # Restart the cache and check if the metadata is still there
        :ok = cache.stop()
        {:ok, _pid} = cache.start_link(root_path: dir)

        # The metadata should not be persisted due to the lock timeout
        assert {:ok, meta} = fetch_meta(cache, "key1")
        assert meta.access_count == 1

        # Stop the cache
        :ok = cache.stop()
      end
    end
  end

  describe "eviction timeout" do
    @start @telemetry_prefix ++ [:evict_expired_entries, :start]
    @stop @telemetry_prefix ++ [:evict_expired_entries, :stop]
    @events [@start, @stop]

    setup %{dir: dir} do
      pid = start_supervised!({DiskCache, root_path: dir, eviction_timeout: 100})

      {:ok, pid: pid}
    end

    test "1: expired entries are evicted", %{cache: cache} do
      with_telemetry_handler @events, fn ->
        :ok = cache.put("key1", "12345", ttl: 50)
        :ok = cache.put("key2", "12345", ttl: 60)
        :ok = cache.put("key3", "12345", ttl: 200)

        assert cache.get_all!() |> Enum.sort() == ["key1", "key2", "key3"]

        assert_receive {@start, %{}, %{count: 0}}, 1000
        assert_receive {@stop, %{}, %{count: 2}}, 1000

        assert cache.get_all!() |> Enum.sort() == ["key3"]

        assert_receive {@start, %{}, %{count: 0}}, 1000
        assert_receive {@stop, %{}, %{count: 1}}, 1000

        assert cache.get_all!() == []
      end
    end
  end

  ## Private functions

  defp fetch_meta(cache, key) do
    Adapter.lookup_meta(cache)
    |> Store.fetch_meta(key, 10)
  end
end
