defmodule Triage.SessionTest do
  # async: false because these tests start globally-named processes
  # (Triage.SessionRegistry / .SessionSupervisor / .PubSub) and attach global
  # telemetry handlers. Keeping it serial avoids name clashes; the reducer's pure
  # tests can still run async alongside other modules.
  use ExUnit.Case, async: false

  alias Triage.{Sessions, Session, State, Supplier}

  @ts "2026-06-22T12:00:00Z"

  # Start the OTP infrastructure fresh for each test. `start_supervised!` links
  # these to the test's supervisor and tears them down automatically afterward.

  # The Registry / DynamicSupervisor / PubSub are started by the application
  # supervision tree, so they're already running under `mix test` — we don't
  # start them here. We just terminate any sessions spawned during a test so the
  # next test starts from a clean DynamicSupervisor.
  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Triage.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Triage.SessionSupervisor, pid)
      end
    end)

    :ok
  end

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

  defp test_state do
    %State{suppliers: [supplier(id: "S-001"), supplier(id: "S-002", program: "Columbia-class")]}
  end

  defp act(map), do: Map.put(map, :ts, @ts)

  defp start_session(id, state) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(Triage.SessionSupervisor, {Session, id: id, state: state})

    id
  end

  # --- tests -----------------------------------------------------------------

  describe "starting and reading a session" do
    test "holds the state it was given" do
      id = start_session("sess_a", test_state())
      {:ok, state} = Sessions.fetch_state(id)
      assert Enum.map(state.suppliers, & &1.id) == ["S-001", "S-002"]
    end
  end

  describe "apply_action through the context" do
    test "runs the reducer and the new state is visible on the next read" do
      id = start_session("sess_b", test_state())

      {:ok, outcome} =
        Sessions.apply_action(
          id,
          act(%{kind: :submit_review, id: "S-001", decision: :flag, rationale: "single-source"})
        )

      assert outcome == {:ok, "Recorded flag for S-001"}

      {:ok, state} = Sessions.fetch_state(id)
      assert Enum.find(state.suppliers, &(&1.id == "S-001")).status == :flagged
    end

    test "a domain error leaves domain state unchanged" do
      id = start_session("sess_c", test_state())

      {:ok, outcome} = Sessions.apply_action(id, act(%{kind: :select_supplier, id: "S-999"}))
      assert {:error, _} = outcome

      {:ok, state} = Sessions.fetch_state(id)
      assert state.selected_id == nil
    end

    test "a missing session is a clean not_found, not a crash" do
      assert Sessions.apply_action("nope", act(%{kind: :clear_filters})) == {:error, :not_found}
      assert Sessions.fetch_state("nope") == {:error, :not_found}
    end
  end

  describe "session isolation" do
    test "an action on one session does not affect another" do
      a = start_session("sess_d1", test_state())
      b = start_session("sess_d2", test_state())

      {:ok, _} =
        Sessions.apply_action(
          a,
          act(%{kind: :submit_review, id: "S-001", decision: :flag, rationale: "x"})
        )

      {:ok, state_b} = Sessions.fetch_state(b)
      assert Enum.find(state_b.suppliers, &(&1.id == "S-001")).status == :unreviewed
    end
  end

  describe "observability side effects" do
    test "broadcasts the new state to subscribers on the session topic" do
      id = start_session("sess_e", test_state())
      Phoenix.PubSub.subscribe(Triage.PubSub, Session.topic(id))

      {:ok, _} =
        Sessions.apply_action(
          id,
          act(%{kind: :submit_review, id: "S-001", decision: :escalate, rationale: "lead time"})
        )

      assert_receive {:state_updated, %State{} = pushed}
      assert Enum.find(pushed.suppliers, &(&1.id == "S-001")).status == :escalated
    end

    test "emits a telemetry event per action with kind and status metadata" do
      test_pid = self()
      handler = "test-telemetry-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:triage, :session, :action],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      id = start_session("sess_f", test_state())
      {:ok, _} = Sessions.apply_action(id, act(%{kind: :add_note, id: "S-001", text: "hi"}))

      assert_receive {:telemetry, [:triage, :session, :action], %{count: 1},
                      %{kind: :add_note, status: :ok}}
    end
  end
end
