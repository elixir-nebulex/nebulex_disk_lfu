defmodule Nebulex.Adapters.DiskLFUTest do
  use ExUnit.Case, async: true
  use Mimic

  defmodule DiskCache do
    use Nebulex.Cache,
      otp_app: :nebulex_disk_lfu,
      adapter: Nebulex.Adapters.DiskLFU
  end

  describe "fetch" do
    setup :setup_cache

    test "ok: fetches a value from the cache", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.fetch("key") == {:ok, "value"}
    end

    test "error: returns error for non-existent key", %{cache: cache} do
      assert_raise Nebulex.KeyError, "key \"nonexistent\" not found", fn ->
        cache.fetch!("nonexistent")
      end
    end

    test "ok: handles binary data", %{cache: cache} do
      binary_data = :crypto.strong_rand_bytes(100)
      :ok = cache.put("binary_key", binary_data)

      assert cache.fetch("binary_key") == {:ok, binary_data}
    end

    test "ok: handles large data", %{cache: cache} do
      large_data = String.duplicate("large data", 1000)
      :ok = cache.put("large_key", large_data)

      assert cache.fetch("large_key") == {:ok, large_data}
    end

    test "ok: handles return options", %{cache: cache} do
      :ok = cache.put("key", "value", metadata: %{foo: "bar"})

      assert cache.fetch("key") == {:ok, "value"}
      assert cache.fetch("key", return: :metadata) == {:ok, %{foo: "bar"}}
      assert cache.fetch("key", return: &{&1, &2}) == {:ok, {"value", %{foo: "bar"}}}

      assert {:ok, symlink} = cache.fetch("key", return: :symlink)
      assert File.exists?(symlink)
      assert File.read!(symlink) == "value"
    end

    test "ok: handles symlink if already exists", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:ln_s, fn _, _ -> {:error, :eexist} end)

      assert {:ok, _symlink} = cache.fetch("key", return: :symlink)
    end

    test "error: symlink creation fails", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:ln_s, fn _, _ -> {:error, :enotsup} end)

      assert_raise Nebulex.Error, "could not fetch key \"key\": operation not supported", fn ->
        cache.fetch!("key", return: :symlink)
      end
    end

    test "error: returns error for expired key", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      assert {:error, %Nebulex.KeyError{reason: :expired}} = cache.fetch("key")
    end

    test "error: file has been removed", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:read, fn _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.KeyError{reason: :not_found}} = cache.fetch("key")
    end
  end

  describe "put" do
    setup :setup_cache

    test "ok: puts a value in the cache", %{cache: cache} do
      assert cache.put("key", "value") == :ok
      assert cache.fetch("key") == {:ok, "value"}

      assert cache.put("key", "value2", ttl: 1000) == :ok
      assert cache.fetch("key") == {:ok, "value2"}
    end

    test "ok: overwrites existing value", %{cache: cache} do
      :ok = cache.put("key", "old_value")
      :ok = cache.put("key", "new_value")

      assert cache.fetch("key") == {:ok, "new_value"}
    end

    test "ok: puts a value in the cache with metadata", %{cache: cache} do
      assert cache.put("key", "value", metadata: %{foo: "bar"}) == :ok
      assert cache.fetch("key") == {:ok, "value"}

      assert cache.fetch("key", return: :metadata) == {:ok, %{foo: "bar"}}
    end

    test "error: raises an error if the key is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the key must be a binary, got: 123", fn ->
        cache.put(123, "value")
      end
    end

    test "error: raises an error if the value is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the value must be a binary, got: nil", fn ->
        cache.put("key", nil)
      end
    end

    test "error: rollback on error", %{cache: cache} do
      File
      |> Mimic.expect(:rename, fn _, _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.put("key", "value")
      assert cache.has_key?("key") == {:ok, false}
    end
  end

  describe "put_all" do
    setup :setup_cache

    test "ok: puts multiple entries at once", %{cache: cache} do
      entries = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]

      assert cache.put_all(entries) == :ok

      assert cache.fetch("key1") == {:ok, "value1"}
      assert cache.fetch("key2") == {:ok, "value2"}
      assert cache.fetch("key3") == {:ok, "value3"}
    end

    test "ok: handles empty entries list", %{cache: cache} do
      assert cache.put_all([]) == :ok
    end

    test "ok: overwrites existing entries", %{cache: cache} do
      :ok = cache.put("key1", "old_value")
      entries = [{"key1", "new_value"}, {"key2", "value2"}]

      assert cache.put_all(entries) == :ok

      assert cache.fetch("key1") == {:ok, "new_value"}
      assert cache.fetch("key2") == {:ok, "value2"}
    end

    test "error: raises an error if the key is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the key must be a binary, got: 123", fn ->
        cache.put_all([{123, "value"}])
      end
    end

    test "error: raises an error if the value is not a binary", %{cache: cache} do
      assert_raise ArgumentError, "the value must be a binary, got: nil", fn ->
        cache.put_all([{"key", nil}])
      end
    end

    test "error: rollback on error", %{cache: cache} do
      File
      |> Mimic.expect(:rename, fn _, _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.put_all([{"key", "value"}])
      assert cache.has_key?("key") == {:ok, false}
    end
  end

  describe "delete" do
    setup :setup_cache

    test "ok: deletes an existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.delete("key") == :ok

      assert_raise Nebulex.KeyError, "key \"key\" not found", fn ->
        cache.fetch!("key")
      end
    end

    test "ok: returns ok for non-existent key", %{cache: cache} do
      assert {:error, %Nebulex.KeyError{reason: :not_found}} = cache.delete("nonexistent")
    end

    test "error: returns error for expired key", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      assert {:error, %Nebulex.KeyError{reason: :expired}} = cache.delete("key")
    end

    test "ok: can delete and then put the same key again", %{cache: cache} do
      :ok = cache.put("key", "value1")
      :ok = cache.delete("key")
      :ok = cache.put("key", "value2")

      assert cache.fetch("key") == {:ok, "value2"}
    end
  end

  describe "take" do
    setup :setup_cache

    test "ok: takes a value and removes it from cache", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.take("key") == {:ok, "value"}

      assert_raise Nebulex.KeyError, "key \"key\" not found", fn ->
        cache.fetch!("key")
      end
    end

    test "ok: handles return options", %{cache: cache} do
      :ok = cache.put("bin", "value", metadata: %{foo: "bar"})
      :ok = cache.put("meta", "value", metadata: %{foo: "bar"})
      :ok = cache.put("{bin, meta}", "value", metadata: %{foo: "bar"})

      assert cache.take("bin") == {:ok, "value"}
      assert cache.take("meta", return: :metadata) == {:ok, %{foo: "bar"}}
      assert cache.take("{bin, meta}", return: &{&1, &2}) == {:ok, {"value", %{foo: "bar"}}}
    end

    test "error: returns error for non-existent key", %{cache: cache} do
      assert_raise Nebulex.KeyError, "key \"nonexistent\" not found", fn ->
        cache.take!("nonexistent")
      end
    end

    test "ok: handles binary data with take", %{cache: cache} do
      binary_data = :crypto.strong_rand_bytes(50)
      :ok = cache.put("binary_key", binary_data)

      assert cache.take("binary_key") == {:ok, binary_data}

      assert_raise Nebulex.KeyError, "key \"binary_key\" not found", fn ->
        cache.fetch!("binary_key")
      end
    end

    test "error: returns error for expired key", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      assert {:error, %Nebulex.KeyError{reason: :expired}} = cache.take("key")
    end
  end

  describe "has_key?" do
    setup :setup_cache

    test "ok: returns true for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.has_key?("key") == {:ok, true}
    end

    test "ok: returns false for non-existent key", %{cache: cache} do
      assert cache.has_key?("nonexistent") == {:ok, false}
    end

    test "ok: returns false after deletion", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.has_key?("key") == {:ok, true}

      :ok = cache.delete("key")

      assert cache.has_key?("key") == {:ok, false}
    end

    test "error: returns an error", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: 1)

      :ok = Process.sleep(100)

      Nebulex.Adapters.DiskLFU.Store
      |> Mimic.expect(:fetch_meta, fn _, _, _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.has_key?("key")
    end
  end

  describe "ttl" do
    setup :setup_cache

    test "ok: returns infinity for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.ttl("key") == {:ok, :infinity}
    end

    test "ok: returns ttl for existing key", %{cache: cache} do
      :ok = cache.put("key", "value", ttl: :timer.seconds(10))

      assert {:ok, ttl} = cache.ttl("key")
      assert ttl > 0
    end

    test "error: returns error for non-existent key", %{cache: cache} do
      assert_raise Nebulex.KeyError, "key \"nonexistent\" not found", fn ->
        cache.ttl!("nonexistent")
      end
    end
  end

  describe "expire" do
    setup :setup_cache

    test "ok: returns true for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.expire("key", 1000) == {:ok, true}

      assert {:ok, ttl} = cache.ttl("key")
      assert ttl > 0
    end

    test "ok: returns false for non-existent key", %{cache: cache} do
      assert cache.expire("nonexistent", 1000) == {:ok, false}
    end

    test "ok: returns false after deletion", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.expire("key", 1000) == {:ok, true}

      :ok = cache.delete("key")

      assert cache.expire("key", 1000) == {:ok, false}
    end

    test "error: returns an error", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:read, fn _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.expire("key", 1000)
    end
  end

  describe "touch" do
    setup :setup_cache

    test "ok: returns true for existing key", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.touch("key") == {:ok, true}
    end

    test "ok: returns false for non-existent key", %{cache: cache} do
      assert cache.touch("nonexistent") == {:ok, false}
    end

    test "ok: returns false after deletion", %{cache: cache} do
      :ok = cache.put("key", "value")

      assert cache.touch("key") == {:ok, true}

      :ok = cache.delete("key")

      assert cache.touch("key") == {:ok, false}
    end

    test "error: returns an error", %{cache: cache} do
      :ok = cache.put("key", "value")

      File
      |> Mimic.expect(:read, fn _ -> {:error, :enoent} end)

      assert {:error, %Nebulex.Error{reason: :enoent}} = cache.touch("key")
    end
  end

  describe "incr" do
    setup :setup_cache

    test "error: raises an error", %{cache: cache} do
      assert {:error, %Nebulex.Error{reason: :not_supported}} = cache.incr("key")
    end
  end

  describe "fetch_or_store" do
    setup :setup_cache

    test "ok: stores the value in the cache if the key does not exist", %{cache: cache} do
      assert cache.fetch_or_store("lazy", fn -> {:ok, "value"} end) == {:ok, "value"}
      assert cache.get!("lazy") == "value"

      assert cache.fetch_or_store("lazy", fn -> {:ok, "new value"} end) == {:ok, "value"}
      assert cache.get!("lazy") == "value"
    end
  end

  describe "count_all" do
    setup :setup_cache

    test "ok: counts all entries", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.count_all() == {:ok, 2}
      assert cache.get!("key1") == "value1"
      assert cache.get!("key2") == "value2"
    end

    test "ok: counts all entries with query", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.count_all(in: ["key1", "key2", "key3"]) == {:ok, 2}
    end
  end

  describe "delete_all" do
    setup :setup_cache

    test "ok: deletes all entries", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.delete_all() == {:ok, 2}

      assert {:error, %Nebulex.KeyError{reason: :not_found}} = cache.fetch("key1")
      assert {:error, %Nebulex.KeyError{reason: :not_found}} = cache.fetch("key2")
    end

    test "ok: deletes all entries with query", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.delete_all(in: ["key1", "key2"]) == {:ok, 2}
    end

    test "ok: deletes all expired entries", %{cache: cache} do
      :ok = cache.put("key1", "value1", ttl: 1)
      :ok = cache.put("key2", "value2", ttl: 1)
      :ok = cache.put("key3", "value3", ttl: :timer.seconds(10))

      :ok = Process.sleep(10)

      assert cache.delete_all!(query: :expired) == 2

      refute cache.get!("key1")
      refute cache.get!("key2")
      assert cache.get!("key3") == "value3"
    end

    test "error: delete given keys fails", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      Nebulex.Adapters.DiskLFU.Store
      |> expect(:delete_from_disk, fn _, _, _ -> {:error, :enoent} end)

      assert cache.delete_all(in: ["key1", "key2"]) == {:ok, 1}

      assert cache.has_key?("key1") == {:ok, true}

      # The key2 should not be deleted because the delete_from_disk failed
      assert cache.has_key?("key2") == {:ok, false}
    end
  end

  describe "get_all" do
    setup :setup_cache

    test "ok: gets all keys", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.get_all!() |> Enum.sort() == ["key1", "key2"]
    end

    test "ok: gets all keys with query", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.get_all!(in: []) == []
      assert cache.get_all!(in: ["key1"]) |> Enum.sort() == ["key1"]
      assert cache.get_all!(in: ["key1", "key2", "key3"]) |> Enum.sort() == ["key1", "key2"]
    end

    test "error: raises an error if the query is not supported", %{cache: cache} do
      assert_raise ArgumentError, "`get_all` does not support query: {:q, \"invalid\"}", fn ->
        cache.get_all(query: "invalid")
      end
    end
  end

  describe "stream" do
    setup :setup_cache

    test "ok: streams all keys", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.stream!() |> Enum.to_list() |> Enum.sort() == ["key1", "key2"]
    end

    test "ok: streams all keys with query", %{cache: cache} do
      :ok = cache.put("key1", "value1")
      :ok = cache.put("key2", "value2")

      assert cache.stream!(in: []) |> Enum.to_list() == []
      assert cache.stream!(in: ["key1"]) |> Enum.to_list() |> Enum.sort() == ["key1"]

      assert cache.stream!(in: ["key1", "key2", "key3"]) |> Enum.to_list() == [
               "key1",
               "key2"
             ]
    end

    test "error: raises an error if the query is not supported", %{cache: cache} do
      assert_raise ArgumentError, ~r"does not support query: {:q, \"invalid\"}", fn ->
        cache.stream!(query: "invalid") |> Enum.to_list()
      end
    end
  end

  describe "transaction" do
    setup :setup_cache

    test "ok: succeeds with default keys", %{cache: cache} do
      assert cache.transaction(fn ->
               cache.put("key", "value")
             end) == {:ok, :ok}
    end

    test "ok: succeeds with the given keys", %{cache: cache} do
      assert cache.transaction(
               fn ->
                 cache.put("key1", "value1")
                 cache.put("key2", "value2")
               end,
               keys: ["key1", "key2"]
             ) == {:ok, :ok}

      assert cache.fetch("key1") == {:ok, "value1"}
      assert cache.fetch("key2") == {:ok, "value2"}
    end
  end

  describe "concurrent operations" do
    setup :setup_cache

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
    test "data persists across cache restarts" do
      dir = Briefly.create!(type: :directory)
      {:ok, _pid} = DiskCache.start_link(root_path: dir)

      :ok = DiskCache.put("persistent_key", "persistent_value")
      :ok = DiskCache.put("another_key", "another_value")

      # Simulate a corrupted meta files
      :ok = File.write!(DiskCache.cache_path() <> "/error_key.meta", :erlang.term_to_binary("meta"))
      :ok = File.write!(DiskCache.cache_path() <> "/exception_key.meta", "invalid")

      # Stop the cache
      :ok = DiskCache.stop()

      # Restart the cache with the same directory
      {:ok, _pid} = DiskCache.start_link(root_path: dir)

      # Verify data is still there
      assert DiskCache.fetch("persistent_key") == {:ok, "persistent_value"}
      assert DiskCache.fetch("another_key") == {:ok, "another_value"}
    end
  end

  describe "required options" do
    test "error: root_path is required" do
      Process.flag(:trap_exit, true)

      assert {:error, {%NimbleOptions.ValidationError{message: message}, _}} =
               DiskCache.start_link(name: :test)

      assert message =~ "required :root_path option not found"
    end
  end

  ## Private functions

  defp setup_cache(_) do
    {pid, dir} = start_cache()

    {:ok, cache: DiskCache, dir: dir, pid: pid}
  end

  defp start_cache do
    dir = Briefly.create!(type: :directory)

    {start_supervised!({DiskCache, root_path: dir}), dir}
  end
end
