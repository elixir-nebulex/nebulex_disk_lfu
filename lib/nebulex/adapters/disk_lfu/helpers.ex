defmodule Nebulex.Adapters.DiskLFU.Helpers do
  @moduledoc """
  Helper functions for the disk LFU adapter.
  """

  import Nebulex.Time, only: [now: 0]

  ## API

  @doc """
  Hashes the given key.
  """
  @spec hash_key(binary()) :: binary()
  def hash_key(key) do
    :sha256
    |> :crypto.hash(key)
    |> Base.encode16()
  end

  @doc """
  Calculates the checksum for the given data.
  """
  @spec checksum(binary()) :: binary()
  def checksum(data) when is_binary(data) do
    :sha
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
    |> then(&("sha-" <> &1))
  end

  @doc """
  Calculates the expiration time for the given TTL.
  """
  @spec expires_at(timeout()) :: timeout()
  def expires_at(ttl) do
    case ttl do
      :infinity -> :infinity
      ttl -> now() + ttl
    end
  end

  @doc """
  Calculates the remaining TTL for the given expiration time.
  """
  @spec remaining_ttl(timeout()) :: timeout()
  def remaining_ttl(expires_at) do
    case expires_at do
      :infinity -> :infinity
      expires_at -> expires_at - now()
    end
  end
end
