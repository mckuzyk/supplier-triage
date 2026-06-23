defmodule TriageWeb.BoardLive do
  @moduledoc """
  The human-facing board for one triage session.

  The key idea: this LiveView is a *client* of the canonical session state,
  exactly like the Python agent is. It never owns state. Its whole job is:

    * subscribe to the session's PubSub topic in `mount/3`
    * render whatever `{:state_updated, state}` message it receives
    * turn human clicks into the *same* actions the agent sends, dispatched
      through the *same* `Sessions.apply_action/2` -> `Reducer.reduce/2` path

  Because every mutation comes back to us as a broadcast, we deliberately do
  NOT patch the socket optimistically on a click. A click dispatches an action;
  the session owner runs the reducer and broadcasts the new state; we re-render
  from that push. The human and the agent are therefore driven by one identical
  state stream — which is the entire point of the project (a person and the
  agent are peer clients of the same state, not two code paths that can drift).

  LiveView lifecycle used here:
    mount/3        — runs once for the static first paint, then again on socket
                     connect; we subscribe only on the connected pass.
    handle_info/2  — receives PubSub broadcasts (agent or human caused them).
    handle_event/3 — receives browser events (phx-click / phx-change / phx-submit).
  """
  use TriageWeb, :live_view

  # Integration points to confirm against the actual server modules:
  #   * Triage.Sessions.fetch_state/1  -> {:ok, state} | {:error, :not_found}
  #   * Triage.Sessions.apply_action/2 -> {:ok, outcome} | {:error, :not_found}
  #   * Triage.Session.topic/1         -> the PubSub topic string for a session
  #   * Triage.SupplierQuery.filter/2  -> filters the full population on read
  #   * PubSub server name             -> assumed Triage.PubSub (the phx.new default)
  alias Triage.{Sessions, Session, SupplierQuery}

  @pubsub Triage.PubSub

  # === lifecycle ============================================================

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # mount/3 is invoked twice. First for the initial HTTP render, where
    # `connected?/1` is false and there is no socket to push diffs over — so we
    # don't subscribe yet. Then again once the websocket is up, where we do.
    if connected?(socket), do: Phoenix.PubSub.subscribe(@pubsub, Session.topic(id))

    socket = assign(socket, session_id: id, page_title: "Triage — #{id}")

    case Sessions.fetch_state(id) do
      {:ok, state} -> {:ok, assign(socket, state: state, not_found: false)}
      {:error, :not_found} -> {:ok, assign(socket, state: nil, not_found: true)}
    end
  end

  # A broadcast from the session owner after *any* action — whether the agent
  # over HTTP or a human in this very browser caused it. One render path.
  @impl true
  def handle_info({:state_updated, state}, socket) do
    {:noreply, assign(socket, state: state)}
  end

  # === human events =========================================================
  # Each clause builds a reducer-native action (snake_case keys, atom enums —
  # the same shape the HTTP action decoder produces for the agent) and
  # dispatches it. We never assign state here; the resulting broadcast does it.

  @impl true
  def handle_event("select_supplier", %{"id" => id}, socket) do
    dispatch(socket, %{kind: :select_supplier, id: id})
  end

  def handle_event("sort_by", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)
    dispatch(socket, %{kind: :sort_by, field: field, dir: next_dir(socket.assigns.state.sort, field)})
  end

  # `phx-change` fires once per changed input; `_target` names which input
  # changed, so we emit a single `apply_filter` for just that field — the
  # contract models one field per action. Selecting the blank "Any" option is a
  # deliberate no-op: the action set has set-a-field and clear-*all*, but no
  # clear-one-field. That's a contract boundary, not something to fake on the
  # client. ("Clear filters" resets everything.)
  def handle_event("filter_change", %{"_target" => [target]} = params, socket) do
    case build_filter(target, Map.get(params, target, "")) do
      :noop -> {:noreply, socket}
      {field, value} -> dispatch(socket, %{kind: :apply_filter, field: field, value: value})
    end
  end

  def handle_event("clear_filters", _params, socket) do
    dispatch(socket, %{kind: :clear_filters})
  end

  def handle_event("add_note", %{"text" => text}, socket) do
    id = socket.assigns.state.selected_id
    text = String.trim(text)

    if is_binary(id) and text != "" do
      dispatch(socket, %{kind: :add_note, id: id, text: text})
    else
      {:noreply, socket}
    end
  end

  def handle_event("submit_review", %{"decision" => decision, "rationale" => rationale}, socket) do
    # The supplier id comes from server-held state (the current selection), not
    # from the form — there's no reason to trust a client-supplied id when we
    # already know which supplier the panel is showing.
    id = socket.assigns.state.selected_id
    rationale = String.trim(rationale)

    cond do
      is_nil(id) ->
        {:noreply, socket}

      rationale == "" ->
        # The reducer/contract require a rationale (minLength 1); we also guard
        # here so the user gets immediate feedback instead of a silent no-op.
        {:noreply, put_flash(socket, :error, "A rationale is required to submit a review.")}

      true ->
        dispatch(socket, %{
          kind: :submit_review,
          id: id,
          decision: String.to_existing_atom(decision),
          rationale: rationale
        })
    end
  end

  # === dispatch =============================================================

  # The single edge between a human click and the state owner. It mirrors what
  # the JSON controller does for the agent: inject a server-side timestamp, then
  # hand the action to the shared context. The reducer stays clock-blind.
  #
  # FLAGGED (see chat): ts is now injected in *two* edges — here and in the
  # controller. Worth considering pushing ts injection down into
  # `Sessions.apply_action/2` so there's one clock-reading edge and the two
  # timestamp representations can't drift. Keeping the controller's behaviour
  # mirrored for now rather than silently re-deciding that.
  defp dispatch(socket, action) do
    action = Map.put(action, :ts, DateTime.utc_now() |> DateTime.to_iso8601())

    case Sessions.apply_action(socket.assigns.session_id, action) do
      {:ok, _outcome} ->
        # Even a domain error (e.g. unknown id) returns {:ok, outcome} and is
        # appended to the log, so the new state — including the refused attempt —
        # arrives via the {:state_updated, _} broadcast. Nothing to do here.
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "This session no longer exists.")}
    end
  end

  # === render ===============================================================

  @impl true
  def render(assigns) do
    # Prepare derived assigns once at the top of render (idiomatic — keeps the
    # template declarative). Filtering is on-read: `state.suppliers` is always
    # the full population in display order, and we derive the visible rows with
    # the same predicate the GET /suppliers endpoint uses.
    assigns =
      if assigns.not_found do
        assigns
      else
        selected = Enum.find(assigns.state.suppliers, &(&1.id == assigns.state.selected_id))

        assign(assigns,
          visible: SupplierQuery.filter(assigns.state.suppliers, assigns.state.filters),
          selected: selected,
          review: selected && assigns.state.reviews[selected.id],
          owner_countries:
            assigns.state.suppliers |> Enum.map(& &1.owner_country) |> Enum.uniq() |> Enum.sort()
        )
      end

    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- Session-not-found state --%>
      <div :if={@not_found} class="mx-auto max-w-md py-24 text-center">
        <h1 class="text-xl font-semibold text-gray-900">Session not found</h1>
        <p class="mt-2 text-sm text-gray-500">
          No triage session with id <code class="font-mono">{@session_id}</code>.
          Create one with <code class="font-mono">POST /api/sessions</code>.
        </p>
      </div>

      <div :if={!@not_found} class="mx-auto max-w-7xl px-4 py-6">
        <header class="mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Supplier-risk triage</h1>
          <p class="text-sm text-gray-500">
            Session <code class="font-mono">{@session_id}</code>
            · {length(@state.suppliers)} suppliers
            · {map_size(@state.reviews)} reviewed
            · <span class="text-green-600">live</span>
          </p>
        </header>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
          <%!-- LEFT: filters + table (two of three columns on large screens) --%>
          <div class="space-y-4 lg:col-span-2">
            <%!-- Filter bar. One <form phx-change> => one apply_filter per change. --%>
            <form
              phx-change="filter_change"
              class="flex flex-wrap items-end gap-3 rounded-lg border border-gray-200 bg-white p-3"
            >
              <label class="flex flex-col text-xs font-medium text-gray-600">
                Program
                <select name="program" class="mt-1 rounded border-gray-300 text-sm">
                  <option value="">Any</option>
                  <option
                    :for={p <- ~w(F-35 Columbia-class GMLRS B-21)}
                    value={p}
                    selected={@state.filters[:program] == p}
                  >
                    {p}
                  </option>
                </select>
              </label>

              <label class="flex flex-col text-xs font-medium text-gray-600">
                Owner country
                <select name="owner_country" class="mt-1 rounded border-gray-300 text-sm">
                  <option value="">Any</option>
                  <option
                    :for={c <- @owner_countries}
                    value={c}
                    selected={@state.filters[:owner_country] == c}
                  >
                    {c}
                  </option>
                </select>
              </label>

              <label class="flex flex-col text-xs font-medium text-gray-600">
                Min foreign % <span class="text-gray-400">(inclusive ≥)</span>
                <select name="min_foreign_pct" class="mt-1 rounded border-gray-300 text-sm">
                  <option value="">Any</option>
                  <%!-- 21 is the strict ">20" boundary from task 1 — picking it
                        is how "over 20%" gets expressed against an inclusive ≥. --%>
                  <option
                    :for={n <- [10, 20, 21, 30, 40, 50]}
                    value={n}
                    selected={@state.filters[:min_foreign_pct] == n}
                  >
                    ≥ {n}
                  </option>
                </select>
              </label>

              <label class="flex flex-col text-xs font-medium text-gray-600">
                Sourcing
                <select name="single_source_only" class="mt-1 rounded border-gray-300 text-sm">
                  <option value="">Any</option>
                  <option value="true" selected={@state.filters[:single_source_only] == true}>
                    Single-source only
                  </option>
                  <option value="false" selected={@state.filters[:single_source_only] == false}>
                    Multi-source only
                  </option>
                </select>
              </label>

              <label class="flex flex-col text-xs font-medium text-gray-600">
                Status
                <select name="status" class="mt-1 rounded border-gray-300 text-sm">
                  <option value="">Any</option>
                  <option
                    :for={s <- ~w(unreviewed flagged cleared escalated)}
                    value={s}
                    selected={to_string(@state.filters[:status]) == s}
                  >
                    {s}
                  </option>
                </select>
              </label>

              <button
                type="button"
                phx-click="clear_filters"
                class="ml-auto rounded border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
              >
                Clear filters
              </button>
            </form>

            <%!-- Supplier table. Headers sort (on-write); rows select. --%>
            <div class="overflow-x-auto rounded-lg border border-gray-200 bg-white">
              <table class="min-w-full text-sm">
                <thead class="bg-gray-50 text-left text-xs uppercase tracking-wide text-gray-500">
                  <tr>
                    <.th field="name" label="Supplier" sort={@state.sort} />
                    <.th field="program" label="Program" sort={@state.sort} />
                    <.th field="tier" label="Tier" sort={@state.sort} />
                    <.th field="owner_country" label="Owner" sort={@state.sort} />
                    <.th field="foreign_ownership_pct" label="Foreign %" sort={@state.sort} />
                    <.th field="single_source" label="Single" sort={@state.sort} />
                    <.th field="lead_time_days" label="Lead (d)" sort={@state.sort} />
                    <.th field="risk_score" label="Risk" sort={@state.sort} />
                    <.th field="status" label="Status" sort={@state.sort} />
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr
                    :for={s <- @visible}
                    phx-click="select_supplier"
                    phx-value-id={s.id}
                    class={[
                      "cursor-pointer hover:bg-blue-50",
                      @state.selected_id == s.id && "bg-blue-100"
                    ]}
                  >
                    <td class="px-3 py-2">
                      <div class="font-medium text-gray-900">{s.name}</div>
                      <div class="font-mono text-xs text-gray-400">{s.id}</div>
                    </td>
                    <td class="px-3 py-2 text-gray-700">{s.program}</td>
                    <td class="px-3 py-2 text-gray-700">{s.tier}</td>
                    <td class="px-3 py-2 text-gray-700">{s.owner_country}</td>
                    <td class="px-3 py-2 text-gray-700">{s.foreign_ownership_pct}%</td>
                    <td class="px-3 py-2 text-gray-700">{if s.single_source, do: "yes", else: "—"}</td>
                    <td class="px-3 py-2 text-gray-700">{s.lead_time_days}</td>
                    <td class="px-3 py-2 text-gray-700">{s.risk_score}</td>
                    <td class="px-3 py-2">
                      <span class={["rounded px-2 py-0.5 text-xs font-medium", status_class(s.status)]}>
                        {s.status}
                      </span>
                    </td>
                  </tr>
                  <tr :if={@visible == []}>
                    <td colspan="9" class="px-3 py-8 text-center text-gray-400">
                      No suppliers match the current filters.
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p class="text-xs text-gray-400">
              Showing {length(@visible)} of {length(@state.suppliers)} suppliers.
            </p>
          </div>

          <%!-- RIGHT: detail/review panel + trace --%>
          <div class="space-y-6">
            <%!-- Detail / review panel --%>
            <div class="rounded-lg border border-gray-200 bg-white p-4">
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-gray-500">
                Detail & review
              </h2>

              <p :if={is_nil(@selected)} class="text-sm text-gray-400">
                Select a supplier to review it.
              </p>

              <div :if={@selected} class="space-y-4">
                <div>
                  <div class="font-medium text-gray-900">{@selected.name}</div>
                  <div class="font-mono text-xs text-gray-400">{@selected.id}</div>
                  <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
                    <dt class="text-gray-500">Program</dt>
                    <dd class="text-gray-900">{@selected.program}</dd>
                    <dt class="text-gray-500">Owner</dt>
                    <dd class="text-gray-900">{@selected.owner_country} ({@selected.foreign_ownership_pct}%)</dd>
                    <dt class="text-gray-500">Single-source</dt>
                    <dd class="text-gray-900">{if @selected.single_source, do: "yes", else: "no"}</dd>
                    <dt class="text-gray-500">Lead time</dt>
                    <dd class="text-gray-900">{@selected.lead_time_days} days</dd>
                    <dt class="text-gray-500">Risk score</dt>
                    <dd class="text-gray-900">{@selected.risk_score}</dd>
                  </dl>
                </div>

                <%!-- Existing review, if any --%>
                <div :if={@review} class="rounded border border-gray-200 bg-gray-50 p-3 text-sm">
                  <div class="font-medium text-gray-700">
                    Reviewed: <span class="uppercase">{@review.decision}</span>
                  </div>
                  <p class="mt-1 text-gray-600">{@review.rationale}</p>
                  <p class="mt-1 text-xs text-gray-400">{@review.ts}</p>
                </div>

                <%!-- Review form (phx-submit, rationale required) --%>
                <form phx-submit="submit_review" class="space-y-2">
                  <label class="block text-xs font-medium text-gray-600">
                    Decision
                    <select name="decision" class="mt-1 w-full rounded border-gray-300 text-sm">
                      <option :for={d <- ~w(flag clear escalate)} value={d}>{d}</option>
                    </select>
                  </label>
                  <label class="block text-xs font-medium text-gray-600">
                    Rationale
                    <textarea
                      name="rationale"
                      rows="2"
                      class="mt-1 w-full rounded border-gray-300 text-sm"
                      placeholder="Why this decision?"
                    ></textarea>
                  </label>
                  <button
                    type="submit"
                    class="w-full rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
                  >
                    Submit review
                  </button>
                </form>

                <%!-- Note form (log-only, per the build) --%>
                <form phx-submit="add_note" class="flex gap-2">
                  <input
                    type="text"
                    name="text"
                    placeholder="Add a note…"
                    class="flex-1 rounded border-gray-300 text-sm"
                  />
                  <button
                    type="submit"
                    class="rounded border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
                  >
                    Note
                  </button>
                </form>
              </div>
            </div>

            <%!-- Trace panel (the append-only log; newest first). Refused
                  actions are logged too, which is what makes the task-4 trap
                  visible here. --%>
            <div class="rounded-lg border border-gray-200 bg-white p-4">
              <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-gray-500">
                Trace
              </h2>
              <ol class="space-y-2 text-sm">
                <li :for={entry <- Enum.reverse(@state.log)} class={["border-l-2 pl-2", trace_border(entry)]}>
                  <div class="flex items-baseline justify-between">
                    <span class="font-mono text-xs text-gray-700">{entry.kind}</span>
                    <span class="text-xs text-gray-400">{entry.ts}</span>
                  </div>
                  <div class={trace_text(entry)}>{entry.outcome.message}</div>
                </li>
                <li :if={@state.log == []} class="text-gray-400">No actions yet.</li>
              </ol>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # === function components ==================================================

  # A sortable column header. Clicking dispatches sort_by; an arrow shows the
  # current sort direction for this column.
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :sort, :map, default: nil

  defp th(assigns) do
    ~H"""
    <th
      phx-click="sort_by"
      phx-value-field={@field}
      class="cursor-pointer select-none px-3 py-2 hover:text-gray-900"
    >
      {@label} <span class="text-gray-400">{sort_indicator(@sort, @field)}</span>
    </th>
    """
  end

  # === pure view helpers ====================================================

  # Clicking a column toggles asc/desc when it's already the sort field,
  # otherwise starts at asc.
  defp next_dir(%{field: field, dir: :asc}, field), do: :desc
  defp next_dir(_sort, _field), do: :asc

  defp sort_indicator(%{field: f, dir: dir}, field) do
    if to_string(f) == field do
      case dir do
        :asc -> "▲"
        :desc -> "▼"
        _ -> ""
      end
    else
      ""
    end
  end

  defp sort_indicator(_sort, _field), do: ""

  # Map a changed form input to a reducer-native {field, value}. Blank => no-op
  # (single-field clear isn't in the contract).
  defp build_filter(_target, ""), do: :noop
  defp build_filter("program", v), do: {:program, v}
  defp build_filter("owner_country", v), do: {:owner_country, v}
  defp build_filter("status", v), do: {:status, v}
  defp build_filter("min_foreign_pct", v), do: {:min_foreign_pct, parse_number(v)}
  defp build_filter("single_source_only", "true"), do: {:single_source_only, true}
  defp build_filter("single_source_only", "false"), do: {:single_source_only, false}
  defp build_filter(_target, _v), do: :noop

  defp parse_number(v) do
    case Integer.parse(v) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> 0
        end
    end
  end

  defp status_class(:flagged), do: "bg-amber-100 text-amber-800"
  defp status_class(:escalated), do: "bg-red-100 text-red-800"
  defp status_class(:cleared), do: "bg-green-100 text-green-800"
  defp status_class(_), do: "bg-gray-100 text-gray-700"

  # Trace entries: a refused/domain-error action is rendered distinctly so the
  # trap demo reads clearly.
  defp ok?(entry), do: to_string(entry.outcome.status) == "ok"
  defp trace_border(entry), do: if(ok?(entry), do: "border-gray-200", else: "border-red-300")
  defp trace_text(entry), do: if(ok?(entry), do: "text-gray-600", else: "text-red-600")
end
