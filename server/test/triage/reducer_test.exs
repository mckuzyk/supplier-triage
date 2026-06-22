defmodule Triage.ReducerTest do
  # `async: true` runs this module concurrently with other test modules. Safe
  # here because the reducer is pure — there's no shared state to race on.
  use ExUnit.Case, async: true

  alias Triage.{Reducer, State, Supplier}

  # A fixed timestamp injected the way the controller will inject it. Because the
  # reducer never reads the clock, we can assert on this exact value.
  @ts "2026-06-22T12:00:00Z"

  # --- fixtures --------------------------------------------------------------

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

  defp base_state do
    %State{
      suppliers: [
        supplier(id: "S-001", program: "F-35", single_source: true, foreign_ownership_pct: 35),
        supplier(id: "S-002", program: "Columbia-class", owner_country: "US", risk_score: 20),
        supplier(id: "S-003", program: "GMLRS", owner_country: "DE")
      ]
    }
  end

  defp sortable_state do
    %State{
      suppliers: [
        supplier(id: "S-001", name: "Charlie", risk_score: 30),
        supplier(id: "S-002", name: "Alpha", risk_score: 90),
        supplier(id: "S-003", name: "Bravo", risk_score: 60)
      ]
    }
  end

  # Every action the controller forwards carries an injected :ts.
  defp act(map), do: Map.put(map, :ts, @ts)

  # --- tests -----------------------------------------------------------------

  describe "apply_filter / clear_filters" do
    test "sets a single filter key" do
      {state, outcome} =
        Reducer.reduce(base_state(), act(%{kind: :apply_filter, field: :program, value: "F-35"}))

      assert outcome == {:ok, "Filter program set to \"F-35\""}
      assert state.filters == %{program: "F-35"}
    end

    test "unknown field is a domain error and leaves filters unchanged" do
      start = base_state()

      {state, outcome} =
        Reducer.reduce(start, act(%{kind: :apply_filter, field: :colour, value: "red"}))

      assert {:error, _} = outcome
      assert state.filters == start.filters
    end

    test "clear_filters empties the filter map" do
      seeded = %{base_state() | filters: %{program: "F-35", min_foreign_pct: 20}}
      {state, {:ok, _}} = Reducer.reduce(seeded, act(%{kind: :clear_filters}))
      assert state.filters == %{}
    end
  end

  describe "sort_by (sort-on-write)" do
    test "reorders stored suppliers by a numeric field descending and records the sort" do
      {state, {:ok, _}} =
        Reducer.reduce(sortable_state(), act(%{kind: :sort_by, field: :risk_score, dir: :desc}))

      assert Enum.map(state.suppliers, & &1.id) == ["S-002", "S-003", "S-001"]
      assert state.sort == %{field: :risk_score, dir: :desc}
    end

    test "reorders by a string field ascending" do
      {state, {:ok, _}} =
        Reducer.reduce(sortable_state(), act(%{kind: :sort_by, field: :name, dir: :asc}))

      # Alpha (S-002), Bravo (S-003), Charlie (S-001)
      assert Enum.map(state.suppliers, & &1.id) == ["S-002", "S-003", "S-001"]
    end

    test "reordering is lossless — the full population is preserved" do
      start = sortable_state()
      {state, _} = Reducer.reduce(start, act(%{kind: :sort_by, field: :risk_score, dir: :asc}))

      assert Enum.sort(Enum.map(state.suppliers, & &1.id)) ==
               Enum.sort(Enum.map(start.suppliers, & &1.id))
    end

    test "rejects an invalid direction and leaves order untouched" do
      start = sortable_state()

      {state, outcome} =
        Reducer.reduce(start, act(%{kind: :sort_by, field: :risk_score, dir: :sideways}))

      assert {:error, _} = outcome
      assert state.suppliers == start.suppliers
      assert state.sort == start.sort
    end
  end

  describe "select_supplier" do
    test "selects an existing supplier" do
      {state, {:ok, _}} = Reducer.reduce(base_state(), act(%{kind: :select_supplier, id: "S-002"}))
      assert state.selected_id == "S-002"
    end

    test "unknown id is a domain error" do
      start = base_state()
      {state, outcome} = Reducer.reduce(start, act(%{kind: :select_supplier, id: "S-999"}))
      assert {:error, _} = outcome
      assert state.selected_id == start.selected_id
    end
  end

  describe "submit_review" do
    test "flag sets status :flagged and records the review with the injected ts" do
      {state, outcome} =
        Reducer.reduce(
          base_state(),
          act(%{
            kind: :submit_review,
            id: "S-001",
            decision: :flag,
            rationale: "single-source, 35% foreign"
          })
        )

      assert outcome == {:ok, "Recorded flag for S-001"}
      assert Enum.find(state.suppliers, &(&1.id == "S-001")).status == :flagged

      assert state.reviews["S-001"] == %{
               decision: :flag,
               rationale: "single-source, 35% foreign",
               ts: @ts
             }
    end

    test "clear and escalate map to the right statuses" do
      {s1, _} =
        Reducer.reduce(base_state(), act(%{kind: :submit_review, id: "S-002", decision: :clear, rationale: "low risk"}))

      {s2, _} =
        Reducer.reduce(base_state(), act(%{kind: :submit_review, id: "S-003", decision: :escalate, rationale: "DE owner"}))

      assert Enum.find(s1.suppliers, &(&1.id == "S-002")).status == :cleared
      assert Enum.find(s2.suppliers, &(&1.id == "S-003")).status == :escalated
    end

    test "rationale is required" do
      start = base_state()

      {state, outcome} =
        Reducer.reduce(start, act(%{kind: :submit_review, id: "S-001", decision: :flag, rationale: "  "}))

      assert {:error, _} = outcome
      assert state.reviews == start.reviews
      assert Enum.find(state.suppliers, &(&1.id == "S-001")).status == :unreviewed
    end

    test "unknown id changes nothing" do
      start = base_state()

      {state, outcome} =
        Reducer.reduce(start, act(%{kind: :submit_review, id: "S-999", decision: :clear, rationale: "n/a"}))

      assert {:error, _} = outcome
      assert state.suppliers == start.suppliers
      assert state.reviews == start.reviews
    end
  end

  describe "the action log (trace)" do
    test "a successful action appends one entry with kind, args, outcome, ts" do
      {state, _} = Reducer.reduce(base_state(), act(%{kind: :select_supplier, id: "S-002"}))

      assert [entry] = state.log
      assert entry.kind == :select_supplier
      assert entry.args == %{id: "S-002"}
      assert entry.outcome == %{status: "ok", message: "Selected S-002"}
      assert entry.ts == @ts
    end

    test "a failed action still appends a log entry but leaves domain state unchanged" do
      start = base_state()
      {state, {:error, _}} = Reducer.reduce(start, act(%{kind: :select_supplier, id: "S-999"}))

      # domain unchanged ...
      assert state.selected_id == start.selected_id
      # ... but the attempt is recorded in the trace
      assert [%{kind: :select_supplier, outcome: %{status: "error"}}] = state.log
    end

    test "add_note preserves the note text in the log args" do
      {state, {:ok, _}} =
        Reducer.reduce(base_state(), act(%{kind: :add_note, id: "S-001", text: "watch this one"}))

      assert [%{kind: :add_note, args: %{id: "S-001", text: "watch this one"}}] = state.log
    end
  end

  describe "purity / determinism" do
    test "same state + same action yields identical results every time" do
      s = base_state()
      a = act(%{kind: :submit_review, id: "S-001", decision: :escalate, rationale: "lead-time risk"})
      assert Reducer.reduce(s, a) == Reducer.reduce(s, a)
    end

    test "the review timestamp is exactly the injected ts (no clock read inside)" do
      {state, _} =
        Reducer.reduce(base_state(), act(%{kind: :submit_review, id: "S-001", decision: :flag, rationale: "x"}))

      assert state.reviews["S-001"].ts == @ts
    end

    test "the trap shape: an unknown kind no-ops the domain and records an error" do
      start = base_state()
      {state, outcome} = Reducer.reduce(start, act(%{kind: :delete_everything}))

      assert {:error, _} = outcome
      assert state.suppliers == start.suppliers
      assert [%{kind: :delete_everything, outcome: %{status: "error"}}] = state.log
    end
  end
end
