defmodule Triage.Sessions do
  @moduledoc """
  The boundary the web layer talks to. The controller calls this context; it never
  touches the GenServer or the Registry directly. This module resolves a session id
  to its process and turns "no such session" into a clean `{:error, :not_found}` the
  controller renders as a 404 — keeping that concern out of the GenServer.

  Note the two layers of result in `apply_action/2`:

      {:ok, {:ok, message}}      session found, action succeeded   -> 200, status "ok"
      {:ok, {:error, message}}   session found, domain refused it  -> 200, status "error"
      {:error, :not_found}       no such session                  -> 404

  The OUTER tuple answers "could we route this request at all?" (an HTTP concern);
  the INNER tuple is the domain outcome from the reducer. They're deliberately not
  collapsed — a missing session and a refused action are different things and map to
  different HTTP responses.
  """

  alias Triage.{Session, State}

  @doc "Create a fresh seeded session under the DynamicSupervisor; returns its id."
  @spec create() :: {:ok, String.t()} | {:error, term()}
  def create do
    id = generate_id()
    state = State.new(load_seed())

    case DynamicSupervisor.start_child(
           Triage.SessionSupervisor,
           {Session, id: id, state: state}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, _reason} = err -> err
    end
  end

  @spec apply_action(String.t(), map()) ::
          {:ok, Triage.Reducer.outcome()} | {:error, :not_found}
  def apply_action(id, action) do
    case Session.whereis(id) do
      nil -> {:error, :not_found}
      pid -> {:ok, Session.apply_action(pid, action)}
    end
  end

  @spec fetch_state(String.t()) :: {:ok, State.t()} | {:error, :not_found}
  def fetch_state(id) do
    case Session.whereis(id) do
      nil -> {:error, :not_found}
      pid -> {:ok, Session.get_state(pid)}
    end
  end

  # ---- helpers ----

  # Not security-sensitive — just needs to be unique and not trivially guessable.
  defp generate_id do
    "sess_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  defp load_seed do
    Application.get_env(:triage, :seed_path, default_seed_path())
    |> File.read!()
    |> Jason.decode!()
  end

  defp default_seed_path, do: Path.join(:code.priv_dir(:triage), "suppliers.seed.json")
end
