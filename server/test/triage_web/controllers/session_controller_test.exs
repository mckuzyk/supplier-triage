defmodule TriageWeb.SessionControllerTest do
  # async: false — these go through the running app (shared Registry / DynamicSupervisor).
  use TriageWeb.ConnCase, async: false

  alias Triage.Sessions

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "content-type", "application/json")}
  end

  test "POST /api/sessions creates a session and returns id + watchUrl", %{conn: conn} do
    conn = post(conn, ~p"/api/sessions")
    assert %{"id" => id, "watchUrl" => url} = json_response(conn, 201)
    assert String.starts_with?(id, "sess_")
    assert url =~ id
  end

  test "a valid action returns 200/ok and the change is visible in state", %{conn: conn} do
    {:ok, id} = Sessions.create()

    conn =
      post(conn, ~p"/api/sessions/#{id}/actions", %{
        kind: "submit_review",
        id: "S-001",
        decision: "flag",
        rationale: "single-source, foreign-owned"
      })

    assert %{"status" => "ok"} = json_response(conn, 200)

    {:ok, state} = Sessions.fetch_state(id)
    assert Enum.find(state.suppliers, &(&1.id == "S-001")).status == :flagged
  end

  test "a body that violates the contract is rejected with 422 (never reaches the reducer)", %{
    conn: conn
  } do
    {:ok, id} = Sessions.create()

    # decision "nope" is not in the contract enum, and rationale is missing.
    conn =
      post(conn, ~p"/api/sessions/#{id}/actions", %{
        kind: "submit_review",
        id: "S-001",
        decision: "nope"
      })

    assert %{"status" => "error"} = json_response(conn, 422)
  end

  test "a domain error (unknown supplier) is 200/error with state untouched", %{conn: conn} do
    {:ok, id} = Sessions.create()

    conn = post(conn, ~p"/api/sessions/#{id}/actions", %{kind: "select_supplier", id: "S-999"})

    assert %{"status" => "error"} = json_response(conn, 200)
    {:ok, state} = Sessions.fetch_state(id)
    assert state.selected_id == nil
  end

  test "an action on a missing session is 404", %{conn: conn} do
    conn = post(conn, ~p"/api/sessions/sess_missing/actions", %{kind: "clear_filters"})
    assert json_response(conn, 404)
  end

  test "GET /state returns the full snapshot in camelCase", %{conn: conn} do
    {:ok, id} = Sessions.create()
    body = conn |> get(~p"/api/sessions/#{id}/state") |> json_response(200)

    assert is_list(body["suppliers"])
    first = hd(body["suppliers"])
    assert Map.has_key?(first, "foreignOwnershipPct")
    assert Map.has_key?(first, "ownerCountry")
  end

  test "GET /suppliers filters by query params", %{conn: conn} do
    {:ok, id} = Sessions.create()

    body =
      conn
      |> get(~p"/api/sessions/#{id}/suppliers?#{[program: "F-35", singleSourceOnly: "true", minForeignPct: "20"]}")
      |> json_response(200)

    assert Enum.all?(body, &(&1["program"] == "F-35"))
    assert Enum.all?(body, &(&1["singleSource"] == true))
    assert Enum.all?(body, &(&1["foreignOwnershipPct"] >= 20))
  end

  test "GET /state on a missing session is 404", %{conn: conn} do
    assert conn |> get(~p"/api/sessions/sess_missing/state") |> json_response(404)
  end
end
