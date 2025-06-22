defmodule Nebulex.Adapters.DiskLFU.Meta do
  @moduledoc """
  Metadata structure for the cache.
  """

  @typedoc "Metadata structure for the cache."
  @type t() :: %__MODULE__{
          access_count: non_neg_integer(),
          last_accessed_at: NaiveDateTime.t(),
          inserted_at: NaiveDateTime.t(),
          size_bytes: non_neg_integer(),
          checksum: binary(),
          base_path: String.t(),
          symlink: String.t() | nil
        }

  @enforce_keys [:last_accessed_at, :inserted_at, :size_bytes, :checksum, :base_path]
  defstruct access_count: 0,
            last_accessed_at: nil,
            inserted_at: nil,
            size_bytes: nil,
            checksum: nil,
            base_path: nil,
            symlink: nil

  ## API

  @doc """
  Creates a new metadata struct.
  """
  @spec new(Enumerable.t()) :: t()
  def new(fields) when is_list(fields) or is_map(fields) do
    struct!(__MODULE__, fields)
  end

  @doc """
  Creates a new metadata struct for the given base path and data.
  """
  @spec new(String.t(), binary()) :: t()
  def new(base_path, data) when is_binary(base_path) and is_binary(data) do
    now = NaiveDateTime.utc_now()

    new(
      base_path: base_path,
      last_accessed_at: now,
      inserted_at: now,
      size_bytes: byte_size(data),
      checksum: checksum(data)
    )
  end

  @doc """
  Updates the access count and last accessed at.
  """
  @spec update_access_count(t()) :: t()
  def update_access_count(%__MODULE__{} = meta) do
    %{meta | access_count: meta.access_count + 1, last_accessed_at: NaiveDateTime.utc_now()}
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
