defmodule TriageWeb.SessionJSON do
  @moduledoc """
  Serializes the internal snake_case structs back to the contract's camelCase JSON.
  This is the encode half of the boundary whose decode half is `Supplier.from_map/1`
  and `TriageWeb.ActionDecoder`. Plain functions returning plain maps; the controller
  hands them to `json/2`.
  """

  alias Triage.{State, Supplier}

  @doc "Full state snapshot (the contract's State schema)."
  def state(%State{} = s) do
    %{
      suppliers: Enum.map(s.suppliers, &supplier/1),
      filters: camelize_keys(s.filters),
      sort: sort(s.sort),
      selectedId: s.selected_id,
      reviews: reviews(s.reviews),
      log: Enum.map(s.log, &log_entry/1)
    }
  end

  @doc "One supplier row (the contract's Supplier schema)."
  def supplier(%Supplier{} = s) do
    %{
      id: s.id,
      name: s.name,
      program: s.program,
      tier: s.tier,
      ownerCountry: s.owner_country,
      foreignOwnershipPct: s.foreign_ownership_pct,
      singleSource: s.single_source,
      leadTimeDays: s.lead_time_days,
      riskScore: s.risk_score,
      status: Atom.to_string(s.status)
    }
  end

  defp sort(nil), do: nil
  defp sort(%{field: field, dir: dir}), do: %{field: camel(field), dir: Atom.to_string(dir)}

  defp reviews(reviews) do
    Map.new(reviews, fn {id, r} ->
      {id, %{decision: Atom.to_string(r.decision), rationale: r.rationale, ts: r.ts}}
    end)
  end

  # The log's `args` and `outcome` are left as-is: they're a free-form object in the
  # contract, and Jason encodes atom keys/values as strings. They reflect the
  # internal (snake_case) shape, which is fine for a trace.
  defp log_entry(entry) do
    %{kind: Atom.to_string(entry.kind), args: entry.args, outcome: entry.outcome, ts: entry.ts}
  end

  defp camelize_keys(map), do: Map.new(map, fn {k, v} -> {camel(k), v} end)

  # :owner_country -> "ownerCountry", :min_foreign_pct -> "minForeignPct", etc.
  defp camel(key) do
    [head | rest] = key |> Atom.to_string() |> String.split("_")
    Enum.join([head | Enum.map(rest, &String.capitalize/1)])
  end
end
