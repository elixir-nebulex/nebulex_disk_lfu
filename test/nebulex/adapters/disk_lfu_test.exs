defmodule Nebulex.Adapters.DiskLFUTest do
  use ExUnit.Case, async: true
  use Mimic

  import Nebulex.Adapters.DiskLFU.TestUtils

  defmodule DiskCache do
    use Nebulex.Cache,
      otp_app: :nebulex_disk_lfu,
      adapter: Nebulex.Adapters.DiskLFU
  end

  setup do
    dir = Briefly.create!(type: :directory)
    {:ok, pid} = DiskCache.start_link(base_dir: dir)

    on_exit(fn -> safe_stop(pid) end)

    {:ok, cache: DiskCache, dir: dir, pid: pid}
  end

  describe "fetch" do
    test "fetches a value from the cache", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.fetch("key") == {:ok, "value"}
    end

    test "returns error for non-existent key", %{cache: cache} do
      assert_raise Nebulex.KeyError, "key \"nonexistent\" not found", fn ->
        cache.fetch!("nonexistent")
      end
    end

    test "handles binary data", %{cache: cache} do
      binary_data = :crypto.strong_rand_bytes(100)
      :ok = cache.put("binary_key", binary_data)

      assert cache.fetch("binary_key") == {:ok, binary_data}
    end

    test "handles large data", %{cache: cache} do
      large_data = String.duplicate("large data", 1000)
      :ok = cache.put("large_key", large_data)

      assert cache.fetch("large_key") == {:ok, large_data}
    end

    test "handles metadata", %{cache: cache} do
      :ok = cache.put("key", "value", metadata: %{foo: "bar"})

      assert cache.fetch("key") == {:ok, "value"}
      assert cache.fetch("key", return: :metadata) == {:ok, %{foo: "bar"}}
      assert cache.fetch("key", return: & &1) == {:ok, {"value", %{foo: "bar"}}}
    end

    test "handles ttl", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      assert {:error, %Nebulex.KeyError{reason: :expired}} = cache.fetch("key")
    end

    test "file has been removed", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:read, fn _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.KeyError{reason: :not_found}} = cache.fetch("key")
    end
  end

  describe "put" do
    test "puts a value in the cache", %{cache: cache} do
      assert cache.put("key", "value") == :ok
      assert cache.fetch("key") == {:ok, "value"}

      assert cache.put("key", "value2", ttl: 1000) == :ok
      assert cache.fetch("key") == {:ok, "value2"}
    end

    test "overwrites existing value", %{cache: cache} do
      :ok = cache.put("key", "old_value")
      :ok = cache.put("key", "new_value")

      assert cache.fetch("key") == {:ok, "new_value"}
    end

    test "puts a value in the cache with metadata", %{cache: cache} do
      assert cache.put("key", "value", metadata: %{foo: "bar"}) == :ok
      assert cache.fetch("key") == {:ok, "value"}

      assert cache.fetch("key", return: :metadata) == {:ok, %{foo: "bar"}}
    end

    test "raises an error if the key is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the key must be a binary, got: 123", fn ->
        cache.put(123, "value")
      end
    end

    test "raises an error if the value is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the value must be a binary, got: nil", fn ->
        cache.put("key", nil)
      end
    end

    test "rollback on error", %{cache: cache} do
      File
      |> Mimic.expect(:rename, fn _, _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.put("key", "value")
      assert cache.has_key?("key") == {:ok, false}
    end
  end

  describe "put_all" do
    test "puts multiple entries at once", %{cache: cache} do
      entries = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]

      assert cache.put_all(entries) == :ok

      assert cache.fetch("key1") == {:ok, "value1"}
      assert cache.fetch("key2") == {:ok, "value2"}
      assert cache.fetch("key3") == {:ok, "value3"}
    end

    test "handles empty entries list", %{cache: cache} do
      assert cache.put_all([]) == :ok
    end

    test "overwrites existing entries", %{cache: cache} do
      :ok = cache.put("key1", "old_value")
      entries = [{"key1", "new_value"}, {"key2", "value2"}]

      assert cache.put_all(entries) == :ok

      assert cache.fetch("key1") == {:ok, "new_value"}
      assert cache.fetch("key2") == {:ok, "value2"}
    end

    test "raises an error if the key is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the key must be a binary, got: 123", fn ->
        cache.put_all([{123, "value"}])
      end
    end

    test "raises an error if the value is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the value must be a binary, got: nil", fn ->
        cache.put_all([{"key", nil}])
      end
    end

    test "rollback on error", %{cache: cache} do
      File
      |> Mimic.expect(:rename, fn _, _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.put_all([{"key", "value"}])
      assert cache.has_key?("key") == {:ok, false}
    end
  end

  describe "delete" do
    test "deletes an existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.delete("key") == :ok

      assert_raise Nebulex.KeyError, "key \"key\" not found", fn ->
        cache.fetch!("key")
      end
    end

    test "returns ok for non-existent key", %{cache: cache} do
      assert {:error, %Nebulex.KeyError{reason: :not_found}} = cache.delete("nonexistent")
    end

    test "handles ttl", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      assert {:error, %Nebulex.KeyError{reason: :expired}} = cache.delete("key")
    end

    test "can delete and then put the same key again", %{cache: cache} do
      :ok = cache.put("key", "value1")
      :ok = cache.delete("key")
      :ok = cache.put("key", "value2")

      assert cache.fetch("key") == {:ok, "value2"}
    end
  end

  describe "take" do
    test "takes a value and removes it from cache", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.take("key") == {:ok, "value"}

      assert_raise Nebulex.KeyError, "key \"key\" not found", fn ->
        cache.fetch!("key")
      end
    end

    test "handles metadata", %{cache: cache} do
      :ok = cache.put("bin", "value", metadata: %{foo: "bar"})
      :ok = cache.put("meta", "value", metadata: %{foo: "bar"})
      :ok = cache.put("{bin, meta}", "value", metadata: %{foo: "bar"})

      assert cache.take("bin") == {:ok, "value"}
      assert cache.take("meta", return: :metadata) == {:ok, %{foo: "bar"}}
      assert cache.take("{bin, meta}", return: & &1) == {:ok, {"value", %{foo: "bar"}}}
    end

    test "returns error for non-existent key", %{cache: cache} do
      assert_raise Nebulex.KeyError, "key \"nonexistent\" not found", fn ->
        cache.take!("nonexistent")
      end
    end

    test "handles binary data with take", %{cache: cache} do
      binary_data = :crypto.strong_rand_bytes(50)
      :ok = cache.put("binary_key", binary_data)

      assert cache.take("binary_key") == {:ok, binary_data}

      assert_raise Nebulex.KeyError, "key \"binary_key\" not found", fn ->
        cache.fetch!("binary_key")
      end
    end

    test "handles ttl", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      assert {:error, %Nebulex.KeyError{reason: :expired}} = cache.take("key")
    end
  end

  describe "has_key?" do
    test "returns true for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.has_key?("key") == {:ok, true}
    end

    test "returns false for non-existent key", %{cache: cache} do
      assert cache.has_key?("nonexistent") == {:ok, false}
    end

    test "returns false after deletion", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.has_key?("key") == {:ok, true}

      :ok = cache.delete("key")

      assert cache.has_key?("key") == {:ok, false}
    end

    test "returns an error", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      Nebulex.Adapters.DiskLFU.Store
      |> Mimic.expect(:fetch_meta, fn _, _, _, _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.has_key?("key")
    end
  end

  describe "ttl" do
    test "returns infinity for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.ttl("key") == {:ok, :infinity}
    end

    test "returns ttl for existing key", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: :timer.seconds(10))

      assert {:ok, ttl} = cache.ttl("key")
      assert ttl > 0
    end

    test "returns error for non-existent key", %{cache: cache} do
      assert_raise Nebulex.KeyError, "key \"nonexistent\" not found", fn ->
        cache.ttl!("nonexistent")
      end
    end
  end

  describe "expire" do
    test "returns true for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.expire("key", 1000) == {:ok, true}

      assert {:ok, ttl} = cache.ttl("key")
      assert ttl > 0
    end

    test "returns false for non-existent key", %{cache: cache} do
      assert cache.expire("nonexistent", 1000) == {:ok, false}
    end

    test "returns false after deletion", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.expire("key", 1000) == {:ok, true}

      :ok = cache.delete("key")

      assert cache.expire("key", 1000) == {:ok, false}
    end

    test "returns an error", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:read, fn _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.expire("key", 1000)
    end
  end

  describe "touch" do
    test "returns true for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.touch("key") == {:ok, true}
    end

    test "returns false for non-existent key", %{cache: cache} do
      assert cache.touch("nonexistent") == {:ok, false}
    end

    test "returns false after deletion", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.touch("key") == {:ok, true}

      :ok = cache.delete("key")

      assert cache.touch("key") == {:ok, false}
    end

    test "returns an error", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:read, fn _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.touch("key")
    end
  end

  describe "incr" do
    test "returns 1 for any counter update", %{cache: cache} do
      assert cache.incr("counter", 5, default: 0) == {:ok, 1}
      assert cache.incr("counter", 10, default: 0) == {:ok, 1}
    end

    test "works with negative amounts", %{cache: cache} do
      assert cache.incr("counter", -5, default: 0) == {:ok, 1}
    end

    test "works with zero amount", %{cache: cache} do
      assert cache.incr("counter", 0, default: 0) == {:ok, 1}
    end
  end

  describe "concurrent operations" do
    test "handles concurrent puts", %{cache: cache} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            cache.put("concurrent_key_#{i}", "value_#{i}")
          end)
        end

      Enum.each(tasks, &Task.await/1)

      for i <- 1..10 do
        assert cache.fetch("concurrent_key_#{i}") == {:ok, "value_#{i}"}
      end
    end

    test "handles concurrent reads", %{cache: cache} do
      :ok = cache.put("read_key", "read_value")

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            cache.fetch("read_key")
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      Enum.each(results, fn result ->
        assert result == {:ok, "read_value"}
      end)
    end
  end

  describe "data persistence" do
    test "data persists across cache restarts", %{cache: cache, dir: dir, pid: pid} do
      :ok = cache.put("persistent_key", "persistent_value")
      :ok = cache.put("another_key", "another_value")

      # Simulate a corrupted meta file
      :ok = File.write!(cache.cache_dir() <> "/error_key.meta", :erlang.term_to_binary("meta"))

      # Stop the cache
      safe_stop(pid)

      # Restart the cache with the same directory
      {:ok, _pid} = DiskCache.start_link(base_dir: dir)

      # Verify data is still there
      assert cache.fetch("persistent_key") == {:ok, "persistent_value"}
      assert cache.fetch("another_key") == {:ok, "another_value"}
    end
  end
end
