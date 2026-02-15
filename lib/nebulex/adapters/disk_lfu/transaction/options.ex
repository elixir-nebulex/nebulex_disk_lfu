defmodule Nebulex.Adapters.DiskLFU.Transaction.Options do
  @moduledoc false

  # Transaction options
  opts_defs = [
    keys: [
      type: {:list, :string},
      required: false,
      default: [],
      doc: """
      The list of keys the transaction will lock.

      Since lock IDs are generated from keys, transactions without keys (or with
      an empty list) use a single global lock ID and are serialized. For better
      concurrency, provide the list of keys involved in the transaction.
      """
    ],
    retries: [
      type: {:or, [:non_neg_integer, {:in, [:infinity]}]},
      type_doc: "`:infinity` | `t:non_neg_integer/0`",
      required: false,
      default: :infinity,
      doc: """
      Number of times to retry lock acquisition before aborting.
      """
    ]
  ]

  # Transaction options schema
  @opts_schema NimbleOptions.new!(opts_defs)

  # Transaction option keys
  @opts Keyword.keys(@opts_schema.schema)

  ## Docs API

  # coveralls-ignore-start

  @spec options_docs() :: binary()
  def options_docs do
    NimbleOptions.docs(@opts_schema)
  end

  # coveralls-ignore-stop

  ## Validation API

  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    opts
    |> Keyword.take(@opts)
    |> NimbleOptions.validate!(@opts_schema)
  end
end
