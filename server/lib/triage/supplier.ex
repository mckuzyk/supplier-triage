defmodule Triage.Supplier do
  @moduledoc """
  One supplier row.

  Internal fields are snake_case Elixir atoms (`foreign_ownership_pct`), which is
  the idiomatic convention. The contract / JSON boundary uses camelCase
  (`foreignOwnershipPct`); that mapping lives here in `from_map/1` (decode) and
  will live in the JSON view (encode) when we build the web layer. The reducer
  itself only ever sees clean snake_case structs.
  """

  @type status :: :unreviewed | :flagged | :cleared | :escalated

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          program: String.t(),
          tier: 1..3,
          owner_country: String.t(),
          foreign_ownership_pct: number(),
          single_source: boolean(),
          lead_time_days: non_neg_integer(),
          risk_score: number(),
          status: status()
        }

  @enforce_keys [
    :id,
    :name,
    :program,
    :tier,
    :owner_country,
    :foreign_ownership_pct,
    :single_source,
    :lead_time_days,
    :risk_score,
    :status
  ]
  defstruct @enforce_keys

  @doc """
  Build a `Supplier` from one decoded seed-JSON object (string, camelCase keys),
  i.e. an element of `contract/suppliers.seed.json`.
  """
  @spec from_map(map()) :: t()
  def from_map(m) when is_map(m) do
    %__MODULE__{
      id: m["id"],
      name: m["name"],
      program: m["program"],
      tier: m["tier"],
      owner_country: m["ownerCountry"],
      foreign_ownership_pct: m["foreignOwnershipPct"],
      single_source: m["singleSource"],
      lead_time_days: m["leadTimeDays"],
      risk_score: m["riskScore"],
      status: status_to_atom(m["status"] || "unreviewed")
    }
  end

  defp status_to_atom("unreviewed"), do: :unreviewed
  defp status_to_atom("flagged"), do: :flagged
  defp status_to_atom("cleared"), do: :cleared
  defp status_to_atom("escalated"), do: :escalated
end
