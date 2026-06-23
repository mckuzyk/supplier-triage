defmodule Triage.Session do
  @moduledoc """
  A GenServer that owns the canonical `Triage.State` for ONE triage session.

  The OTP shape, in plain terms:

    * **One process per session.** Each session is an isolated GenServer. Memory,
      message queue, and crashes are per-session — one session cannot corrupt or
      block another. That isolation is the BEAM giving you concurrency for free.
    * **Named via a Registry.** Rather than passing pids around, each process
      registers itself under its session id in `Triage.SessionRegistry` using a
      `:via` tuple. Callers find a session by id; they never hold a raw pid.
    * **Started under a DynamicSupervisor.** Sessions are created on demand (when a
      client POSTs `/api/sessions`), so they live under `Triage.SessionSupervisor`,
      a `DynamicSupervisor` that starts children at runtime instead of at boot.

  This process is the *only* writer of its state. A call arrives, we run the pure
  `Reducer.reduce/2`, store the result, emit telemetry, and broadcast the new state
  to subscribers (the LiveView) — all inside one `handle_call`, so the transition
  and the notification are serialized together and can't interleave with another
  action. The reducer stays pure; every side effect lives out here.

  The action arriving here already carries its `:ts` — the controller injects the
  timestamp at the HTTP edge, so neither this process nor the reducer reads a clock.
  """

  use GenServer

  alias Triage.{Reducer, State}

  @registry Triage.SessionRegistry
  @pubsub Triage.PubSub
  @telemetry_event [:triage, :session, :action]

  # ---- client API (callers deal in ids/pids; the message protocol stays here) ----

  @doc "Start a session process holding the given pre-built state, named by `id`."
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    state = Keyword.fetch!(opts, :state)
    GenServer.start_link(__MODULE__, {id, state}, name: via(id))
  end

  @doc "Resolve a session id to its pid, or nil if no such session is running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "Apply one (already timestamped) action; returns the reducer's outcome."
  @spec apply_action(pid(), map()) :: Reducer.outcome()
  def apply_action(pid, action) when is_pid(pid) do
    GenServer.call(pid, {:apply_action, action})
  end

  @doc "Read the current full state snapshot."
  @spec get_state(pid()) :: State.t()
  def get_state(pid) when is_pid(pid), do: GenServer.call(pid, :get_state)

  @doc """
  The PubSub topic for a session. Exposed so the LiveView and the tests subscribe
  to the exact same string — one source of truth for the topic name.
  """
  @spec topic(String.t()) :: String.t()
  def topic(id), do: "session:" <> id

  defp via(id), do: {:via, Registry, {@registry, id}}

  # ---- server callbacks ----

  @impl true
  def init({id, %State{} = state}) do
    {:ok, %{id: id, state: state}}
  end

  @impl true
  def handle_call(:get_state, _from, data) do
    {:reply, data.state, data}
  end

  @impl true
  def handle_call({:apply_action, action}, _from, %{id: id, state: state} = data) do
    start = System.monotonic_time()
    {new_state, outcome} = Reducer.reduce(state, action)
    duration = System.monotonic_time() - start

    :telemetry.execute(
      @telemetry_event,
      %{count: 1, duration: duration},
      %{session_id: id, kind: action.kind, status: outcome_status(outcome)}
    )

    # Notify observers (the LiveView) that state changed. We broadcast on EVERY
    # action, including domain errors, because the log gained an entry either way —
    # so the trace panel updates live even when an action is refused.
    Phoenix.PubSub.broadcast(@pubsub, topic(id), {:state_updated, new_state})

    {:reply, outcome, %{data | state: new_state}}
  end

  defp outcome_status({:ok, _}), do: :ok
  defp outcome_status({:error, _}), do: :error
end
