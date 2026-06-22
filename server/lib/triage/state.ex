defmodule Triage.State do
  @moduledoc """
  The one canonical state for a triage session.

  This is a plain data struct with no behavior. The reducer is the only thing
  that produces a new version of it. Keeping data dumb (here) and transitions in
  one pure function (`Triage.Reducer`) is the usual Elixir shape and is what
  makes the core testable.

  `filters` and `selected_id` are *view/pointer state*, not a mutation of
  `suppliers`: a filter records a visibility criterion applied at read time (the
  `GET /suppliers` endpoint and the LiveView table share one filter predicate),
  and `selected_id` just names the row open in the detail panel.

  `sort`, by contrast, is applied *on write*: `sort_by` reorders `suppliers` in
  place — reordering is lossless, so the full population is preserved — and also
  records the criterion in `sort` so readers can show "sorted by X". The
  invariant: `suppliers` is always the complete population, in current display
  order. The only other thing that mutates a supplier is a review changing its
  status.
  """

  alias Triage.Supplier

  @type sort :: %{field: atom(), dir: :asc | :desc} | nil
  @type review :: %{decision: atom(), rationale: String.t(), ts: String.t()}

  @type t :: %__MODULE__{
          suppliers: [Supplier.t()],
          filters: %{optional(atom()) => term()},
          sort: sort(),
          selected_id: String.t() | nil,
          reviews: %{optional(String.t()) => review()},
          log: [map()]
        }

  defstruct suppliers: [],
            filters: %{},
            sort: nil,
            selected_id: nil,
            reviews: %{},
            log: []

  @doc """
  Build the initial seeded state from a list of seed-JSON supplier maps
  (as loaded from `contract/suppliers.seed.json` on session create).
  """
  @spec new([map()]) :: t()
  def new(supplier_maps) when is_list(supplier_maps) do
    %__MODULE__{suppliers: Enum.map(supplier_maps, &Supplier.from_map/1)}
  end
end
