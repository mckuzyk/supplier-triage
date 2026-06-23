defmodule Triage.Reducer do
  @moduledoc """
  The deterministic core. `reduce/2` is a pure function: given the current state
  and one action, it returns `{new_state, outcome}` and nothing else.

  Pure means:

    * no I/O, no message sends, no telemetry — the controller does those *around*
      the reducer, never inside it;
    * no randomness;
    * no clock reads. The timestamp is *passed in* on the action as `:ts` (the
      controller injects it on every action before calling reduce). This is what
      lets the tests assert exact timestamps.

  It is also **goal-blind and LLM-blind**: it has no idea an agent exists or what
  the agent is trying to accomplish. It just applies one well-formed action.

  `outcome` is `{:ok, message}` or `{:error, message}`. On `:error` the returned
  *domain* state (suppliers / filters / sort / selection / reviews) is unchanged —
  actions never partially apply. The append-only `log` is the one thing that does
  change on an error: every attempt, success or domain-failure, is recorded so the
  trace shows what was tried (this is what makes eval task 4, the "wipe the
  database" trap, observable). If you'd rather errors leave zero trace, that's a
  one-line change in `reduce/2`.
  """

  alias Triage.{State, Supplier, SupplierQuery}

  @type outcome :: {:ok, String.t()} | {:error, String.t()}

  @filter_fields ~w(program owner_country min_foreign_pct single_source_only status)a
  @sort_fields ~w(name program tier owner_country foreign_ownership_pct single_source lead_time_days risk_score status)a
  @sort_dirs ~w(asc desc)a

  # decision (action verb) -> resulting supplier status
  @decisions %{flag: :flagged, clear: :cleared, escalate: :escalated}

  @spec reduce(State.t(), map()) :: {State.t(), outcome()}
  def reduce(%State{} = state, %{kind: _} = action) do
    {new_state, outcome} = apply_action(state, action)
    {log(new_state, action, outcome), outcome}
  end

  # ---- one clause per action kind -------------------------------------------

  defp apply_action(state, %{kind: :apply_filter, field: field, value: value})
       when field in @filter_fields do
    {%{state | filters: Map.put(state.filters, field, value)},
     {:ok, "Filter #{field} set to #{inspect(value)}"}}
  end

  defp apply_action(state, %{kind: :apply_filter, field: field}) do
    {state, {:error, "Unknown filter field: #{inspect(field)}"}}
  end

  defp apply_action(state, %{kind: :clear_filters}) do
    {%{state | filters: %{}}, {:ok, "Filters cleared"}}
  end

  defp apply_action(state, %{kind: :sort_by, field: field, dir: dir})
       when field in @sort_fields and dir in @sort_dirs do
    # sort-on-write: reorder the canonical list now, and record the criterion so
    # the UI/agent can read "currently sorted by X". `dir` is already :asc/:desc,
    # which is exactly what Enum.sort_by/3 wants as its sorter — no translation.
    # Ordering uses Erlang term order: fine for numbers/strings; note that
    # :single_source sorts false-before-true and :status sorts alphabetically
    # (cleared, escalated, flagged, unreviewed), NOT by severity. Drop in a custom
    # comparator if you want a domain order on those.
    sorted = SupplierQuery.sort(state.suppliers, %{field: field, dir: dir})

    {%{state | suppliers: sorted, sort: %{field: field, dir: dir}},
     {:ok, "Sorted by #{field} #{dir}"}}
  end

  defp apply_action(state, %{kind: :sort_by} = a) do
    {state, {:error, "Invalid sort: #{inspect(Map.take(a, [:field, :dir]))}"}}
  end

  defp apply_action(state, %{kind: :select_supplier, id: id}) do
    if supplier_exists?(state, id) do
      {%{state | selected_id: id}, {:ok, "Selected #{id}"}}
    else
      {state, {:error, "Unknown supplier id: #{id}"}}
    end
  end

  # add_note has no first-class home in the State schema (see the open question
  # I flagged). Here it validates the id, then records the note via the log
  # entry's args and makes no other domain change. If you want first-class notes,
  # add a `notes` field to the contract's State schema and a clause here.
  defp apply_action(state, %{kind: :add_note, id: id, text: text}) do
    cond do
      not supplier_exists?(state, id) -> {state, {:error, "Unknown supplier id: #{id}"}}
      blank?(text) -> {state, {:error, "Note text cannot be empty"}}
      true -> {state, {:ok, "Note added to #{id}"}}
    end
  end

  defp apply_action(state, %{
         kind: :submit_review,
         id: id,
         decision: decision,
         rationale: rationale,
         ts: ts
       }) do
    cond do
      not Map.has_key?(@decisions, decision) ->
        {state, {:error, "Invalid decision: #{inspect(decision)}"}}

      blank?(rationale) ->
        {state, {:error, "Rationale is required"}}

      not supplier_exists?(state, id) ->
        {state, {:error, "Unknown supplier id: #{id}"}}

      true ->
        new_status = Map.fetch!(@decisions, decision)
        review = %{decision: decision, rationale: rationale, ts: ts}

        {%{
           state
           | suppliers: set_status(state.suppliers, id, new_status),
             reviews: Map.put(state.reviews, id, review)
         }, {:ok, "Recorded #{decision} for #{id}"}}
    end
  end

  defp apply_action(state, %{kind: kind}) do
    {state, {:error, "Unknown action kind: #{inspect(kind)}"}}
  end

  # ---- helpers --------------------------------------------------------------

  defp supplier_exists?(state, id), do: Enum.any?(state.suppliers, &(&1.id == id))

  defp set_status(suppliers, id, status) do
    Enum.map(suppliers, fn
      %Supplier{id: ^id} = s -> %{s | status: status}
      s -> s
    end)
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Append-only trace. Chronological order, so we append (`++`). For a demo's
  # bounded action count that's fine; for high volume you'd prepend and reverse
  # on read. The outcome is stored in its serialized Outcome shape because the
  # log rides along inside the JSON state snapshot.
  defp log(state, action, outcome) do
    entry = %{
      kind: action.kind,
      args: Map.drop(action, [:kind, :ts]),
      outcome: outcome_to_map(outcome),
      ts: Map.get(action, :ts)
    }

    %{state | log: state.log ++ [entry]}
  end

  defp outcome_to_map({:ok, msg}), do: %{status: "ok", message: msg}
  defp outcome_to_map({:error, msg}), do: %{status: "error", message: msg}
end
