defmodule Nebulex.Adapters.DiskLFU.Meta do
  @moduledoc """
  Metadata structure for the cache.
  """

  import Nebulex.Time, only: [now: 0]

  @typedoc "Metadata structure for the cache."
  @type t() :: %__MODULE__{
          base_path: String.t(),
          size_bytes: non_neg_integer(),
          checksum: binary(),
          access_count: non_neg_integer(),
          inserted_at: non_neg_integer(),
          last_accessed_at: non_neg_integer(),
          expires_at: timeout()
        }

  @enforce_keys ~w(base_path size_bytes checksum inserted_at last_accessed_at)a
  defstruct base_path: nil,
            size_bytes: nil,
            checksum: nil,
            access_count: 0,
            inserted_at: nil,
            last_accessed_at: nil,
            expires_at: :infinity

  ## API

  @doc """
  Creates a new metadata struct.
  """
  @spec new(Enumerable.t()) :: t()
  def new(fields) when is_list(fields) or is_map(fields) do
    struct!(__MODULE__, fields)
  end

  @doc """
  Creates a new metadata struct for the given data.
  """
  @spec new(binary(), keyword()) :: t()
  def new(data, fields) when is_binary(data) and is_list(fields) do
    now = now()

    [
      last_accessed_at: now,
      inserted_at: now,
      size_bytes: byte_size(data),
      checksum: checksum(data)
    ]
    |> Keyword.merge(fields)
    |> new()
  end

  @doc """
  Updates the access count and last accessed at.
  """
  @spec update_access_count(t()) :: t()
  def update_access_count(%__MODULE__{} = meta) do
    %{meta | access_count: meta.access_count + 1, last_accessed_at: now()}
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
  Encodes the metadata to a binary.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = meta) do
    :erlang.term_to_binary(Map.put(meta, :checksum, meta.checksum))
  end

  @doc """
  Decodes the metadata from a binary.
  """
  # sobelow_skip ["Misc.BinToTerm"]
  @spec decode(binary()) :: {:ok, t()} | :error
  def decode(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary) do
      %__MODULE__{} = meta ->
        {:ok, meta}

      _error ->
        :error
    end
  end
end
