"""Derive agent tool schemas from the OpenAPI contract (no SDK dependency).

This is the single-source-of-truth half of the agent tools: it reads
`contract/actions.openapi.yaml` — the same file the Phoenix server validates
against — and produces, per action `kind`, a JSON Schema ready to hand to the
Agent SDK's `@tool`. Nothing here imports the SDK, so it's unit-testable on its
own (the spirit of the project's pure-core / thin-adapter split).

What it reads, and why each is authoritative:
  * write actions  <- components.schemas.Action.discriminator.mapping
        (kind -> variant schema; the contract's own list of valid kinds)
  * read tools     <- paths[...].get parameters, keyed by operationId
  * enums/types    <- resolved inline from $ref (Program, SortField, ...)

OpenAPI 3.0 schema objects are JSON Schema draft-ish; this contract uses only
the compatible subset (type/enum/oneOf/minLength/minimum/maximum), so resolved
schemas pass straight through to `@tool` with no translation.
"""

from __future__ import annotations

import copy
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

# Same file the Phoenix server loads. Default resolves to <repo>/contract/...
# relative to agent/src/, overridable via TRIAGE_CONTRACT.
DEFAULT_CONTRACT_PATH = os.environ.get(
    "TRIAGE_CONTRACT",
    str(Path(__file__).resolve().parents[2] / "contract" / "actions.openapi.yaml"),
)


@dataclass(frozen=True)
class ToolSpec:
    name: str  # tool name == action kind, e.g. "apply_filter"
    description: str
    input_schema: dict[str, Any]
    method: str  # "post" (action) | "get" (read)
    kind: str | None  # discriminator value to inject for POST actions; None for reads
    path_template: str  # e.g. "actions" or "state" or "suppliers"


def load_spec(path: str | None = None) -> dict[str, Any]:
    with open(path or DEFAULT_CONTRACT_PATH) as f:
        return yaml.safe_load(f)


def _resolve(node: Any, spec: dict[str, Any]) -> Any:
    """Recursively inline local $refs (#/components/...) so the result is
    self-contained JSON Schema. Refs in this contract are acyclic (enums)."""
    if isinstance(node, dict):
        if "$ref" in node:
            ref = node["$ref"]
            assert ref.startswith("#/"), f"only local refs supported: {ref}"
            target: Any = spec
            for part in ref.lstrip("#/").split("/"):
                target = target[part]
            return _resolve(target, spec)
        return {k: _resolve(v, spec) for k, v in node.items()}
    if isinstance(node, list):
        return [_resolve(v, spec) for v in node]
    return node


def action_tool_specs(spec: dict[str, Any]) -> list[ToolSpec]:
    """One ToolSpec per write-action kind, from the Action discriminator."""
    action = spec["components"]["schemas"]["Action"]
    mapping = action["discriminator"]["mapping"]
    specs: list[ToolSpec] = []
    for kind, ref in mapping.items():
        variant = _resolve({"$ref": ref}, spec)
        schema = copy.deepcopy(variant)
        # `kind` is the discriminator — the wrapper injects it, the model must not.
        schema.get("properties", {}).pop("kind", None)
        if "required" in schema:
            schema["required"] = [r for r in schema["required"] if r != "kind"]
            if not schema["required"]:
                schema.pop("required")
        schema.setdefault("type", "object")
        specs.append(
            ToolSpec(
                name=kind,
                description=(variant.get("description") or "").strip(),
                input_schema=schema,
                method="post",
                kind=kind,
                path_template="actions",
            )
        )
    return specs


def _op_by_id(spec: dict[str, Any], op_id: str) -> tuple[str, dict[str, Any]]:
    for path, item in spec["paths"].items():
        for method, op in item.items():
            if isinstance(op, dict) and op.get("operationId") == op_id:
                return path, op
    raise KeyError(op_id)


def read_tool_specs(spec: dict[str, Any]) -> list[ToolSpec]:
    """ToolSpecs for the GET read tools (get_state, query_suppliers)."""
    specs: list[ToolSpec] = []

    _, get_state = _op_by_id(spec, "getState")
    specs.append(
        ToolSpec(
            name="get_state",
            description=(get_state.get("summary") or "").strip(),
            input_schema={"type": "object", "properties": {}},
            method="get",
            kind=None,
            path_template="state",
        )
    )

    _, query = _op_by_id(spec, "querySuppliers")
    props: dict[str, Any] = {}
    required: list[str] = []
    for param in query.get("parameters", []):
        param = _resolve(param, spec)
        if param.get("in") != "query":  # skip the SessionId path param
            continue
        props[param["name"]] = param["schema"]
        if param.get("required"):
            required.append(param["name"])
    schema: dict[str, Any] = {"type": "object", "properties": props}
    if required:
        schema["required"] = required
    specs.append(
        ToolSpec(
            name="query_suppliers",
            description=(query.get("summary") or "").strip(),
            input_schema=schema,
            method="get",
            kind=None,
            path_template="suppliers",
        )
    )
    return specs


def all_tool_specs(spec: dict[str, Any]) -> list[ToolSpec]:
    return action_tool_specs(spec) + read_tool_specs(spec)


if __name__ == "__main__":
    import json
    import sys

    spec = load_spec(sys.argv[1] if len(sys.argv) > 1 else None)
    for ts in all_tool_specs(spec):
        print(f"\n=== {ts.name}  [{ts.method} {ts.path_template}]  kind={ts.kind}")
        print("desc:", repr(ts.description))
        print(json.dumps(ts.input_schema, indent=2))
