defmodule Nebulex.Adapters.DiskLFU.TestUtils do
  @moduledoc false

  @doc false
  def safe_stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5000)
  catch
    # Perhaps the `pid` has terminated already (race-condition),
    # so we don't want to crash the test
    :exit, _ -> :ok
  end
end
