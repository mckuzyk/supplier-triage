"""Agent-side tools for the supplier-triage action API.

Tool SCHEMAS are generated from the contract (contract.py reads the same
`actions.openapi.yaml` the Phoenix server validates against), so fields, enums,
and required-ness physically cannot drift from the server. Tool DESCRIPTIONS —
the model-facing prose — live in the DESCRIPTIONS overlay below, merged over any
description the contract carries. The split is deliberate: a stale enum would
produce invalid actions and eval failures (so it's generated), while prose is
tuning (so it's overlaid). See DECISIONS.md / HANDOFF.md.

Design notes
------------
* `session_id` is NOT a model-visible argument. Tools are produced by
  `build_triage_tools(session_id, base_url, client)`, which closes over the id
  and a shared httpx.AsyncClient. Threading the id is implementation, not the
  model's job. Supplier ids ARE model-supplied where the contract requires them.
* `_post_action` / `_get` are the pure HTTP layer; the generated handlers are
  thin adapters over them. The `__main__` block drives the HTTP layer with no
  model and no SDK — the Python sibling of HANDOFF.md's `curl` smoke test.

Tool names the model sees are `mcp__<server>__<tool>`; with server "triage"
that's `mcp__triage__apply_filter`, etc. Use `triage_tool_names("triage")`.
"""

from __future__ import annotations

import json
from typing import Any

import httpx
from claude_agent_sdk import tool, create_sdk_mcp_server

import contract  # pure deriver; no SDK dependency

DEFAULT_BASE_URL = "http://localhost:4000"

# --- model-facing prose, merged OVER contract descriptions -------------------
# Structural truth (fields/enums/required) comes from the contract; this is only
# the wording the model reads. Anything that is really an API *semantic* — e.g.
# the minForeignPct inclusive-bound note — is better added to the contract's own
# description fields (see the YAML note in the chat) so the server surfaces it
# too; entries here then become redundant and can be dropped.
DESCRIPTIONS: dict[str, str] = {
    "apply_filter": (
        "Set ONE filter field on the shared board everyone watches. value type "
        "depends on field: program/ownerCountry/status are strings (exact enum "
        "values), minForeignPct is a number, singleSourceOnly is a boolean. "
        "There is no clear-one-field action — use clear_filters to reset all."
    ),
    "clear_filters": "Clear ALL active board filters at once (the only clear action available).",
    "sort_by": (
        "Reorder the board by a field, ascending or descending. Lossless: it "
        "sorts the full population, it does not filter anything out."
    ),
    "select_supplier": (
        "Select a supplier by id to focus it in the detail/review panel. Use an "
        "id that exists in the data; never invent one."
    ),
    "add_note": (
        "Attach a free-text note to a supplier (recorded in the action trace). "
        "Does not change a supplier's status — use submit_review for decisions."
    ),
    "submit_review": (
        "Record the terminal triage decision for ONE supplier (flag, clear, or "
        "escalate). A non-empty rationale is REQUIRED on every review. Do not "
        "include a timestamp — the server stamps it."
    ),
    "get_state": (
        "Fetch the full current state snapshot: every supplier with its status, "
        "the active filters, sort, selection, reviews, and the action log. Read-only."
    ),
    "query_suppliers": (
        "Look up suppliers by criteria WITHOUT touching the shared board's "
        "filters. All parameters optional; omit to leave a dimension unfiltered. "
        "IMPORTANT: minForeignPct is an INCLUSIVE lower bound "
        "(foreignOwnershipPct >= value), so 'foreign ownership over 20%' means "
        "minForeignPct=21, not 20 — querying 20 would wrongly include a supplier "
        "sitting exactly at 20%."
    ),
}


def _description_for(spec: contract.ToolSpec) -> str:
    """Overlay wins; fall back to the contract's own description; never empty."""
    desc = DESCRIPTIONS.get(spec.name) or spec.description
    if not desc:
        raise ValueError(
            f"tool {spec.name!r} has no description — add one to the contract "
            f"or to the DESCRIPTIONS overlay before shipping it to the model."
        )
    return desc


def triage_tool_names(
    server_name: str = "triage", contract_path: str | None = None
) -> list[str]:
    """allowed_tools entries for ClaudeAgentOptions, derived from the contract."""
    spec = contract.load_spec(contract_path)
    return [f"mcp__{server_name}__{ts.name}" for ts in contract.all_tool_specs(spec)]


# --- pure HTTP layer (no SDK dependency; directly testable) ------------------


async def _post_action(
    client: httpx.AsyncClient, base_url: str, session_id: str, body: dict[str, Any]
) -> dict[str, Any]:
    """POST one action; return parsed JSON. The server returns 200 + {status,
    message} for both ok and *domain* errors (e.g. unknown id) — legitimate
    results the model should read, so we surface the body rather than raise."""
    resp = await client.post(f"{base_url}/api/sessions/{session_id}/actions", json=body)
    return _parse(resp)


async def _get(
    client: httpx.AsyncClient,
    base_url: str,
    session_id: str,
    path: str,
    params: dict[str, Any] | None = None,
) -> Any:
    resp = await client.get(
        f"{base_url}/api/sessions/{session_id}/{path}", params=params or {}
    )
    return _parse(resp)


def _parse(resp: httpx.Response) -> Any:
    try:
        data = resp.json()
    except ValueError:
        data = {"status": "error", "message": resp.text}
    if resp.status_code >= 400 and isinstance(data, dict):
        data.setdefault(
            "httpStatus", resp.status_code
        )  # tell 422/404 from a domain outcome
    return data


def _ok(payload: Any) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(payload)}]}


def _err(message: str) -> dict[str, Any]:
    # is_error signals a *tool* failure (transport), not a domain error (which
    # comes back as a normal 200 Outcome with status="error").
    return {"content": [{"type": "text", "text": message}], "is_error": True}


# --- tool factory: schemas from contract, handlers generic ------------------


def build_triage_tools(
    session_id: str,
    base_url: str = DEFAULT_BASE_URL,
    client: httpx.AsyncClient | None = None,
    contract_path: str | None = None,
):
    """Return the list of SDK tools bound to one session, generated from the
    contract. `client` lets agent.py own the httpx lifecycle."""
    http = client or httpx.AsyncClient(timeout=10.0)
    spec = contract.load_spec(contract_path)

    def make_handler(ts: contract.ToolSpec):
        async def handler(args: dict[str, Any]) -> dict[str, Any]:
            try:
                if ts.method == "post":
                    body = {"kind": ts.kind, **args}
                    return _ok(await _post_action(http, base_url, session_id, body))
                if ts.path_template == "suppliers":
                    params = {k: v for k, v in args.items() if v is not None}
                    return _ok(
                        await _get(http, base_url, session_id, "suppliers", params)
                    )
                return _ok(await _get(http, base_url, session_id, ts.path_template))
            except httpx.RequestError as e:
                return _err(f"Could not reach the action API: {e!r}")

        return handler

    # `tool(name, description, schema)` is the decorator form; called directly it
    # wraps a handler into an SdkMcpTool, which is all we need to build at runtime.
    return [
        tool(ts.name, _description_for(ts), ts.input_schema)(make_handler(ts))
        for ts in contract.all_tool_specs(spec)
    ]


def build_triage_server(
    session_id: str,
    base_url: str = DEFAULT_BASE_URL,
    client: httpx.AsyncClient | None = None,
    server_name: str = "triage",
    contract_path: str | None = None,
):
    """Bundle the generated tools into an in-process SDK MCP server."""
    return create_sdk_mcp_server(
        name=server_name,
        version="0.1.0",
        tools=build_triage_tools(session_id, base_url, client, contract_path),
    )


# --- session lifecycle helper (not a model tool) ----------------------------


async def create_session(
    base_url: str = DEFAULT_BASE_URL, client: httpx.AsyncClient | None = None
) -> dict[str, Any]:
    """POST /api/sessions -> {id, watchUrl}. Call once, up front, in agent.py."""
    own = client is None
    http = client or httpx.AsyncClient(timeout=10.0)
    try:
        resp = await http.post(f"{base_url}/api/sessions")
        resp.raise_for_status()
        return resp.json()
    finally:
        if own:
            await http.aclose()


# --- model-free smoke test: drives the HTTP layer directly -------------------

if __name__ == "__main__":
    import asyncio

    async def _smoke() -> None:
        sp = contract.load_spec()
        names = [ts.name for ts in contract.all_tool_specs(sp)]
        print("generated tools:", names)

        async with httpx.AsyncClient(timeout=10.0) as client:
            session = await create_session(client=client)
            sid = session["id"]
            print("session:", sid, "watch:", session.get("watchUrl"))

            hits = await _get(
                client,
                DEFAULT_BASE_URL,
                sid,
                "suppliers",
                {"program": "F-35", "singleSourceOnly": True, "minForeignPct": 21},
            )
            print("F-35 single-source >20%:", [s["id"] for s in hits])
            # expect ["S-001","S-002","S-003","S-018"]  (S-004 at exactly 20 excluded)

            print(
                "review:",
                await _post_action(
                    client,
                    DEFAULT_BASE_URL,
                    sid,
                    {
                        "kind": "submit_review",
                        "id": "S-001",
                        "decision": "flag",
                        "rationale": "Single-source F-35 part, 35% German ownership.",
                    },
                ),
            )
            print(
                "bad id:",
                await _post_action(
                    client,
                    DEFAULT_BASE_URL,
                    sid,
                    {"kind": "select_supplier", "id": "S-999"},
                ),
            )

    asyncio.run(_smoke())

