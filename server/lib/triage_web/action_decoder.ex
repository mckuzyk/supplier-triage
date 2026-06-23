defmodule TriageWeb.ActionDecoder do
  @moduledoc """
  Turns a contract-validated request body into the internal action map the reducer
  speaks: a snake_case, atom-keyed map with an atom `:kind`.

  This runs AFTER `OpenApiSpex.cast_and_validate/3` has accepted the body, so it can
  assume a well-formed shape and only needs to do two things: translate naming (the
  contract is camelCase, the core is snake_case) and lift known enum strings to
  atoms. Pure and side-effect-free, so it's unit-tested directly without HTTP.

  It accepts either string- or atom-keyed input, so it's robust to however the cast
  layer hands back `conn.body_params`.
  """

  @spec decode(map()) :: map()
  def decode(body), do: body |> stringify_keys() |> do_decode()

  defp do_decode(%{"kind" => "apply_filter", "field" => field, "value" => value}),
    do: %{kind: :apply_filter, field: field_atom(field), value: value}

  defp do_decode(%{"kind" => "clear_filters"}),
    do: %{kind: :clear_filters}

  defp do_decode(%{"kind" => "sort_by", "field" => field, "dir" => dir}),
    do: %{kind: :sort_by, field: field_atom(field), dir: String.to_existing_atom(dir)}

  defp do_decode(%{"kind" => "select_supplier", "id" => id}),
    do: %{kind: :select_supplier, id: id}

  defp do_decode(%{"kind" => "add_note", "id" => id, "text" => text}),
    do: %{kind: :add_note, id: id, text: text}

  defp do_decode(%{
         "kind" => "submit_review",
         "id" => id,
         "decision" => decision,
         "rationale" => rationale
       }),
       do: %{kind: :submit_review, id: id, decision: String.to_existing_atom(decision), rationale: rationale}

  # The contract names fields in camelCase (ownerCountry, foreignOwnershipPct); the
  # core uses snake_case atoms. Macro.underscore converts mechanically, and
  # to_existing_atom doubles as a guard — an unrecognized field would raise rather
  # than silently mint a new atom (the snake atoms all already exist: they're
  # struct keys or entries in the reducer's allow-lists).
  defp field_atom(field), do: field |> Macro.underscore() |> String.to_existing_atom()

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
