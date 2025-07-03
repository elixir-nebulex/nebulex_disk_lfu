defmodule Nebulex.Adapters.DiskLFU.TestUtils do
  @moduledoc false

  alias Nebulex.Telemetry

  @doc false
  def safe_stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5000)
  catch
    # Perhaps the `pid` has terminated already (race-condition),
    # so we don't want to crash the test
    :exit, _ -> :ok
  end

  @doc false
  def with_telemetry_handler(handler_id \\ self(), events, fun) do
    :ok =
      Telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_event/4,
        %{pid: self()}
      )

    fun.()
  after
    Telemetry.detach(handler_id)
  end

  @doc false
  def handle_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {event, measurements, metadata})
  end
end
