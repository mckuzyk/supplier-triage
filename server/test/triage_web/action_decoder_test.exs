defmodule TriageWeb.ActionDecoderTest do
  use ExUnit.Case, async: true

  alias TriageWeb.ActionDecoder

  test "apply_filter maps a camelCase field to a snake_case atom and keeps the value as-is" do
    assert ActionDecoder.decode(%{"kind" => "apply_filter", "field" => "ownerCountry", "value" => "US"}) ==
             %{kind: :apply_filter, field: :owner_country, value: "US"}
  end

  test "sort_by lifts both field and dir to atoms" do
    assert ActionDecoder.decode(%{
             "kind" => "sort_by",
             "field" => "foreignOwnershipPct",
             "dir" => "desc"
           }) == %{kind: :sort_by, field: :foreign_ownership_pct, dir: :desc}
  end

  test "submit_review lifts the decision to an atom but leaves id/rationale as strings" do
    assert ActionDecoder.decode(%{
             "kind" => "submit_review",
             "id" => "S-001",
             "decision" => "flag",
             "rationale" => "single-source, foreign-owned"
           }) == %{
             kind: :submit_review,
             id: "S-001",
             decision: :flag,
             rationale: "single-source, foreign-owned"
           }
  end

  test "clear_filters needs no args" do
    assert ActionDecoder.decode(%{"kind" => "clear_filters"}) == %{kind: :clear_filters}
  end

  test "is robust to atom-keyed input (defensive against the cast layer's key format)" do
    assert ActionDecoder.decode(%{kind: "clear_filters"}) == %{kind: :clear_filters}
  end
end
