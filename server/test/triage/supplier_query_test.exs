defmodule Triage.SupplierQueryTest do
  use ExUnit.Case, async: true

  alias Triage.{SupplierQuery, Supplier}

  defp supplier(attrs) do
    defaults = %{
      id: "S-001",
      name: "Acme",
      program: "F-35",
      tier: 1,
      owner_country: "US",
      foreign_ownership_pct: 0,
      single_source: false,
      lead_time_days: 100,
      risk_score: 50,
      status: :unreviewed
    }

    struct!(Supplier, Map.merge(defaults, Map.new(attrs)))
  end

  defp suppliers do
    [
      supplier(id: "S-001", program: "F-35", single_source: true, foreign_ownership_pct: 35, owner_country: "DE"),
      supplier(id: "S-002", program: "F-35", single_source: false, foreign_ownership_pct: 10, owner_country: "US"),
      supplier(id: "S-003", program: "Columbia-class", single_source: true, foreign_ownership_pct: 40, owner_country: "NO", status: :flagged)
    ]
  end

  describe "filter/2" do
    test "no criteria returns everything" do
      assert length(SupplierQuery.filter(suppliers(), %{})) == 3
    end

    test "program filter" do
      assert Enum.map(SupplierQuery.filter(suppliers(), %{program: "F-35"}), & &1.id) == ["S-001", "S-002"]
    end

    test "minForeignPct is an inclusive lower bound" do
      assert Enum.map(SupplierQuery.filter(suppliers(), %{min_foreign_pct: 35}), & &1.id) == ["S-001", "S-003"]
    end

    test "singleSourceOnly true keeps only single-source; false is a no-op" do
      assert Enum.map(SupplierQuery.filter(suppliers(), %{single_source_only: true}), & &1.id) == ["S-001", "S-003"]
      assert length(SupplierQuery.filter(suppliers(), %{single_source_only: false})) == 3
    end

    test "status compares against the stringified atom" do
      assert Enum.map(SupplierQuery.filter(suppliers(), %{status: "flagged"}), & &1.id) == ["S-003"]
    end

    test "criteria combine with AND" do
      result = SupplierQuery.filter(suppliers(), %{program: "F-35", single_source_only: true})
      assert Enum.map(result, & &1.id) == ["S-001"]
    end
  end

  describe "sort/2" do
    test "sorts by a numeric field descending" do
      result = SupplierQuery.sort(suppliers(), %{field: :foreign_ownership_pct, dir: :desc})
      assert Enum.map(result, & &1.id) == ["S-003", "S-001", "S-002"]
    end
  end
end
