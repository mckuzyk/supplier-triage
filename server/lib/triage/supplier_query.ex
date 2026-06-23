defmodule Triage.SupplierQuery do
  @moduledoc """
  Pure read-side projections over a list of suppliers: filtering by a criteria map
  and sorting by a field/dir.

  Shared in two directions so logic lives in one place: `filter/2`'s predicate is
  the same one the LiveView board will use (fed `state.filters` instead of query
  params), and `sort/2` is the comparator the reducer's sort-on-write calls, so the
  ordering rule can't drift between the write path and the read path.
  """

  @doc "Keep suppliers matching every criterion in `filters` (snake_case atom keys)."
  @spec filter([map()], map()) :: [map()]
  def filter(suppliers, filters) when is_map(filters) do
    Enum.filter(suppliers, fn s ->
      Enum.all?(filters, fn {field, value} -> matches?(s, field, value) end)
    end)
  end

  @doc """
  Sort by field/dir. Uses Erlang term ordering — fine for numbers/strings; note
  (as in the reducer) that booleans sort false-before-true and status sorts
  alphabetically, not by severity.
  """
  @spec sort([map()], %{field: atom(), dir: :asc | :desc}) :: [map()]
  def sort(suppliers, %{field: field, dir: dir}) do
    Enum.sort_by(suppliers, &Map.fetch!(&1, field), dir)
  end

  defp matches?(s, :program, v), do: s.program == v
  defp matches?(s, :owner_country, v), do: s.owner_country == v
  defp matches?(s, :min_foreign_pct, v), do: s.foreign_ownership_pct >= v
  defp matches?(s, :single_source_only, true), do: s.single_source
  defp matches?(_s, :single_source_only, _), do: true
  defp matches?(s, :status, v), do: Atom.to_string(s.status) == to_string(v)
end
