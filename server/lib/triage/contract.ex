defmodule Triage.Contract do
  @moduledoc """
  Loads `contract/actions.openapi.yaml` — the single source of truth — into an
  `%OpenApiSpex.OpenApi{}` struct and indexes its operations by operationId.

  The controller validates every request against THIS loaded spec (via
  `OpenApiSpex.cast_and_validate/3`). Because validation reads the same YAML the
  Python agent generates its tools from, the server's accepted inputs and the
  agent's tools cannot drift — which is the entire point of the contract.

  Decoding turns strings into atoms, so we only ever load our own trusted, local
  file, and we do it ONCE (memoized in `:persistent_term`) rather than per request.
  Set the path in config:

      config :triage, contract_path: Path.expand("../../contract/actions.openapi.yaml", __DIR__)
  """

  alias OpenApiSpex.{OpenApi, Operation, PathItem}

  @doc "The full decoded contract spec."
  @spec spec() :: OpenApi.t()
  def spec, do: load().spec

  @doc "Fetch one operation by its operationId (e.g. `:applyAction`)."
  @spec operation(atom()) :: Operation.t()
  def operation(operation_id), do: Map.fetch!(load().operations, operation_id)

  # --- loading / caching ---

  defp load do
    case :persistent_term.get({__MODULE__, :loaded}, nil) do
      nil ->
        loaded = build()
        :persistent_term.put({__MODULE__, :loaded}, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp build do
    spec =
      Application.fetch_env!(:triage, :contract_path)
      |> YamlElixir.read_all_from_file!()
      |> List.first()
      |> OpenApi.Decode.decode()

    %{spec: spec, operations: index_operations(spec)}
  end

  defp index_operations(spec) do
    for {_path, %PathItem{} = item} <- spec.paths,
        %Operation{operationId: op_id} = operation <- operations_of(item),
        is_binary(op_id),
        into: %{},
        do: {String.to_atom(op_id), operation}
  end

  defp operations_of(%PathItem{} = item) do
    [item.get, item.post, item.put, item.patch, item.delete] |> Enum.reject(&is_nil/1)
  end
end
