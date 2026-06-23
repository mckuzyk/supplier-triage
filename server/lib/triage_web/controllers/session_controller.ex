defmodule TriageWeb.SessionController do
  @moduledoc """
  The action API faces the agent. Two endpoints so far:

    * `POST /api/sessions` — create a fresh seeded session, return its id + watch URL.
    * `POST /api/sessions/:id/actions` — the one mutation endpoint. Validate the body
      against the contract, inject the timestamp, run it through the reducer, return
      the outcome.

  The read endpoints (`GET .../state`, `GET .../suppliers`) and their JSON views are
  the next step.

  The response-status contract:

      201  session created
      200  action processed — body `{status: "ok"|"error", message}` (domain result)
      404  no such session
      422  body failed contract validation
  """
  use TriageWeb, :controller

  alias Triage.{Sessions, Contract, SupplierQuery}
  alias TriageWeb.{ActionDecoder, SessionJSON}

  def create(conn, _params) do
    {:ok, id} = Sessions.create()
    watch_url = "#{TriageWeb.Endpoint.url()}/board/#{id}"

    conn
    |> put_status(:created)
    |> json(%{id: id, watchUrl: watch_url})
  end

  def apply_action(conn, %{"id" => id}) do
    case OpenApiSpex.cast_and_validate(Contract.spec(), Contract.operation(:applyAction), conn) do
      {:ok, conn} ->
        # The clock lives here, at the HTTP edge: we inject :ts so neither the
        # session process nor the reducer ever reads time.
        action =
          conn.body_params
          |> ActionDecoder.decode()
          |> Map.put(:ts, DateTime.utc_now() |> DateTime.to_iso8601())

        case Sessions.apply_action(id, action) do
          # 200 either way: an "ok" or a domain "error" are both successfully
          # *processed* actions. Only a missing session is a routing failure.
          {:ok, outcome} -> json(conn, to_outcome(outcome))
          {:error, :not_found} -> send_not_found(conn)
        end

      {:error, errors} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: render_errors(errors)})
    end
  end

  defp to_outcome({:ok, message}), do: %{status: "ok", message: message}
  defp to_outcome({:error, message}), do: %{status: "error", message: message}

  defp send_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", message: "Session not found"})
  end

  defp render_errors(errors) when is_list(errors) do
    errors |> Enum.map(&OpenApiSpex.Cast.Error.message/1) |> Enum.join("; ")
  end

  defp render_errors(other), do: inspect(other)

  def state(conn, %{"id" => id}) do
    case Sessions.fetch_state(id) do
      {:ok, state} -> json(conn, SessionJSON.state(state))
      {:error, :not_found} -> send_not_found(conn)
    end
  end

  def suppliers(conn, %{"id" => id} = params) do
    case Sessions.fetch_state(id) do
      {:ok, state} ->
        result =
          state.suppliers
          |> SupplierQuery.filter(parse_filters(params))
          |> maybe_sort(parse_sort(params))

        json(conn, Enum.map(result, &SessionJSON.supplier/1))

      {:error, :not_found} ->
        send_not_found(conn)
    end
  end

  @sortable ~w(name program tier owner_country foreign_ownership_pct single_source lead_time_days risk_score status)a

  defp parse_filters(params) do
    %{}
    |> put_if(:program, params["program"])
    |> put_if(:owner_country, params["ownerCountry"])
    |> put_if(:min_foreign_pct, parse_number(params["minForeignPct"]))
    |> put_if(:single_source_only, parse_bool(params["singleSourceOnly"]))
    |> put_if(:status, params["status"])
  end

  defp parse_sort(params) do
    with field when is_binary(field) <- params["sortField"],
         {:ok, atom} <- existing_atom(Macro.underscore(field)),
         true <- atom in @sortable do
      %{field: atom, dir: parse_dir(params["sortDir"])}
    else
      _ -> nil
    end
  end

  defp maybe_sort(suppliers, nil), do: suppliers
  defp maybe_sort(suppliers, sort), do: SupplierQuery.sort(suppliers, sort)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp parse_number(nil), do: nil
  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_dir("desc"), do: :desc
  defp parse_dir(_), do: :asc

  defp existing_atom(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end
end
