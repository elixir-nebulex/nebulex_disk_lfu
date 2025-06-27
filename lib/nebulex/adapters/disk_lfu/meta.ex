defmodule Nebulex.Adapters.DiskLFU.Meta do
  @moduledoc """
  Metadata for the cache.
  """

  @typedoc "Metadata structure for the cache."
  @type t() :: %__MODULE__{
          checksum: binary(),
          size_bytes: non_neg_integer(),
          access_count: non_neg_integer(),
          inserted_at: non_neg_integer(),
          last_accessed_at: non_neg_integer(),
          expires_at: timeout(),
          metadata: map()
        }

  @enforce_keys ~w(checksum size_bytes inserted_at last_accessed_at)a
  defstruct checksum: nil,
            size_bytes: nil,
            access_count: 0,
            inserted_at: nil,
            last_accessed_at: nil,
            expires_at: :infinity,
            metadata: %{}
end
