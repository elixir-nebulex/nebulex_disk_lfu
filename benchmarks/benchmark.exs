## Benchmarks

binary = :crypto.strong_rand_bytes(10_000_000)

defmodule Cache do
  @moduledoc false
  use Nebulex.Cache,
    otp_app: :nebulex,
    adapter: Nebulex.Adapters.DiskLFU
end

benchmarks = %{
  "fetch" => fn ->
    Cache.fetch("fetch")
  end,
  "put" => fn ->
    Cache.put("put", binary)
  end,
  "delete" => fn ->
    Cache.delete("delete")
  end
}

# Start cache
dir = Briefly.create!(type: :directory)
{:ok, pid} = Cache.start_link(root_path: dir)

Cache.put_all([{"fetch", binary}, {"delete", binary}])

Benchee.run(
  benchmarks,
  formatters: [
    {Benchee.Formatters.Console, comparison: false, extended_statistics: true},
    {Benchee.Formatters.HTML, extended_statistics: true, auto_open: false}
  ],
  print: [
    fast_warning: false
  ]
)

# Stop cache
if Process.alive?(pid), do: Supervisor.stop(pid)
