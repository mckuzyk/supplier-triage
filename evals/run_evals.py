"""End-to-end eval harness for the supplier-triage agent.

Per task: spin a fresh session (run_goal already does this), run the agent over
the NL goal, then GET /state and run the deterministic checker in tasks.py over
*final state*. K runs per task gives a reliability number. The agent is trusted
for nothing — the disposition that counts is what's in the canonical state, not
what the agent says it did (MEMO-session-handoff-and-report.md).

Two metric denominators, kept separate (HANDOFF-3):
  * **server log** — actions that went through reduce/2 (incl. refused attempts).
    "actions/task" = log entries; "reviews/task" = successful submit_reviews;
    "invalid/task" = entries whose outcome.status == "error".
  * **agent-side tool_calls** — what the model invoked. Split into action tools /
    read tools (get_state, query_suppliers) / other. The SDK's deferred-tool
    "ToolSearch" call has no `mcp__triage__` prefix, so it lands in "other" and
    never pollutes the action/read counts.

LLM-as-judge scores task-3 rationale *quality* only, on a separate column. It
never gates the deterministic pass/fail — the escalation id + non-empty
rationale is the pass; the judge is commentary on top.

Assumes the Phoenix server is already up (same contract as agent.py). Writes a
per-run JSON artifact and a summary (json + markdown) under evals/results/.

Run:
    uv run --env-file .env python evals/run_evals.py            # K=3, all tasks
    uv run --env-file .env python evals/run_evals.py --k 10     # final pass
    uv run --env-file .env python evals/run_evals.py --task t1 --task t3
    uv run --env-file .env python evals/run_evals.py --no-judge
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean
from typing import Any

import httpx

# tasks.py lives next to this file.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import tasks as T  # noqa: E402

# agent.py / tools.py live in agent/src; put it on the path for the lazy import.
_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT / "agent" / "src"))

DEFAULT_BASE_URL = os.environ.get("TRIAGE_BASE_URL", "http://localhost:4000")
DEFAULT_JUDGE_MODEL = os.environ.get("TRIAGE_JUDGE_MODEL", "claude-sonnet-4-6")
ANTHROPIC_VERSION = "2023-06-01"

READ_TOOL_SUFFIXES = ("__get_state", "__query_suppliers")
TRIAGE_PREFIX = "mcp__triage__"
MUTATING_KINDS = {
    "apply_filter",
    "clear_filters",
    "sort_by",
    "select_supplier",
    "submit_review",
}


# ---------------------------------------------------------------------------
# Pure metrics (no SDK, no network — unit-testable on their own)
# ---------------------------------------------------------------------------


def server_metrics(state: dict) -> dict[str, Any]:
    """Counts derived from the canonical action log in final state."""
    log = state.get("log", []) or []
    by_kind: dict[str, int] = {}
    invalid = 0
    reviews_ok = 0
    for e in log:
        kind = e.get("kind", "?")
        by_kind[kind] = by_kind.get(kind, 0) + 1
        status = (e.get("outcome") or {}).get("status")
        if status == "error":
            invalid += 1
        if kind == "submit_review" and status == "ok":
            reviews_ok += 1
    return {
        "log_entries": len(log),  # all action attempts through reduce/2
        "reviews_ok": reviews_ok,  # successful dispositions
        "invalid_actions": invalid,  # outcome.status == "error" (refused/no-op)
        "by_kind": by_kind,
    }


def agent_metrics(tool_calls: list[dict]) -> dict[str, Any]:
    """Split agent-side tool calls into action / read / other (ToolSearch etc.)."""
    ours = [
        tc for tc in tool_calls if str(tc.get("name", "")).startswith(TRIAGE_PREFIX)
    ]
    reads = [tc for tc in ours if str(tc["name"]).endswith(READ_TOOL_SUFFIXES)]
    actions = [tc for tc in ours if tc not in reads]
    other = [tc for tc in tool_calls if tc not in ours]
    return {
        "tool_calls_total": len(tool_calls),
        "triage_tool_calls": len(ours),
        "action_calls": len(actions),
        "read_calls": len(reads),
        "other_calls": len(other),  # SDK ToolSearch + anything non-triage
    }


def _safe_mean(xs: list[float | int | None]) -> float | None:
    vals = [x for x in xs if x is not None]
    return round(mean(vals), 3) if vals else None


def aggregate(task_key: str, records: list[dict]) -> dict[str, Any]:
    """Roll up K per-run records for one task into summary metrics."""
    n = len(records)
    completed = [r for r in records if r.get("error") is None]
    passes = sum(1 for r in completed if r["passed"])
    judged = [
        r["judge"]["score"]
        for r in completed
        if r.get("judge") and r["judge"].get("score") is not None
    ]
    return {
        "task": task_key,
        "runs": n,
        "completed": len(completed),
        "errored": n - len(completed),
        "passes": passes,
        "pass_rate": round(passes / n, 3) if n else None,
        "mean_actions": _safe_mean([r["server"]["log_entries"] for r in completed]),
        "mean_reviews": _safe_mean([r["server"]["reviews_ok"] for r in completed]),
        "mean_invalid": _safe_mean([r["server"]["invalid_actions"] for r in completed]),
        "mean_tool_calls": _safe_mean(
            [r["agent"]["triage_tool_calls"] for r in completed]
        ),
        "mean_reads": _safe_mean([r["agent"]["read_calls"] for r in completed]),
        "mean_duration_s": _safe_mean(
            [
                (r["run_meta"]["duration_ms"] / 1000.0)
                if r["run_meta"]["duration_ms"] is not None
                else None
                for r in completed
            ]
        ),
        "mean_cost_usd": _safe_mean(
            [r["run_meta"]["total_cost_usd"] for r in completed]
        ),
        "mean_judge": _safe_mean(judged) if judged else None,
    }


def _fmt(v: Any) -> str:
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.2f}"
    return str(v)


def to_markdown(summaries: list[dict], k: int, base_url: str) -> str:
    cols = [
        ("Task", "task"),
        (f"Pass /{k}", None),
        ("Pass rate", "pass_rate"),
        ("Actions*", "mean_actions"),
        ("Reviews", "mean_reviews"),
        ("Invalid", "mean_invalid"),
        ("Tool calls", "mean_tool_calls"),
        ("Reads", "mean_reads"),
        ("Dur (s)", "mean_duration_s"),
        ("Cost ($)", "mean_cost_usd"),
        ("Judge", "mean_judge"),
    ]
    header = "| " + " | ".join(c[0] for c in cols) + " |"
    sep = "| " + " | ".join("---" for _ in cols) + " |"
    rows = []
    for s in summaries:
        cells = []
        for label, key in cols:
            if key is None:  # the "Pass /k" column
                err = f" (+{s['errored']} err)" if s["errored"] else ""
                cells.append(f"{s['passes']}/{s['runs']}{err}")
            else:
                cells.append(_fmt(s[key]))
        rows.append("| " + " | ".join(cells) + " |")
    legend = (
        "\n*Actions* = mean server-log entries per task (all actions through "
        "`reduce/2`, including refused attempts). **Reviews** = mean successful "
        "`submit_review`s. **Invalid** = mean log entries with `outcome.status="
        '"error"`. **Tool calls / Reads** = agent-side counts (SDK `ToolSearch` '
        "excluded). **Judge** = mean rationale-quality score (task 3 only, 1–5, "
        "non-gating)."
    )
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return (
        f"# Supplier-triage eval run\n\n_{ts} · K={k} · server={base_url}_\n\n{header}\n{sep}\n"
        + "\n".join(rows)
        + "\n"
        + legend
        + "\n"
    )


# ---------------------------------------------------------------------------
# Network: fetch final state + LLM-as-judge
# ---------------------------------------------------------------------------


async def fetch_state(client: httpx.AsyncClient, base_url: str, sid: str) -> dict:
    resp = await client.get(f"{base_url}/api/sessions/{sid}/state", timeout=10.0)
    resp.raise_for_status()
    return resp.json()


_JUDGE_RUBRIC = """You are scoring the QUALITY of a one-supplier triage rationale.
The analyst escalated this supplier for worst lead-time exposure on its program.

Supplier (ground-truth data):
{supplier}

Rationale written:
"{rationale}"

Score 1–5 on whether the rationale is:
- grounded in THIS supplier's actual data (esp. lead time / program exposure),
- specific rather than generic boilerplate,
- free of invented facts not present in the data above.

Respond with ONLY a JSON object, no prose, no code fences:
{{"score": <int 1-5>, "reason": "<one sentence>"}}"""


async def judge_rationale(
    client: httpx.AsyncClient, model: str, api_key: str, supplier: dict, rationale: str
) -> dict | None:
    prompt = _JUDGE_RUBRIC.format(
        supplier=json.dumps(supplier, indent=2), rationale=rationale.replace('"', "'")
    )
    try:
        resp = await client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": ANTHROPIC_VERSION,
                "content-type": "application/json",
            },
            json={
                "model": model,
                "max_tokens": 300,
                "messages": [{"role": "user", "content": prompt}],
            },
            timeout=30.0,
        )
        resp.raise_for_status()
        data = resp.json()
        text = "".join(
            b.get("text", "")
            for b in data.get("content", [])
            if b.get("type") == "text"
        )
        text = (
            text.strip()
            .removeprefix("```json")
            .removeprefix("```")
            .removesuffix("```")
            .strip()
        )
        parsed = json.loads(text)
        return {"score": int(parsed["score"]), "reason": str(parsed.get("reason", ""))}
    except Exception as exc:  # judge is best-effort; never fail a run on it
        return {"score": None, "reason": f"judge error: {exc}"}


# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------


async def run_one(
    task: T.Task,
    run_index: int,
    *,
    run_goal,
    http: httpx.AsyncClient,
    base_url: str,
    model: str,
    max_turns: int,
    judge: bool,
    judge_model: str,
    api_key: str | None,
    verbose: bool,
) -> dict:
    rec: dict[str, Any] = {
        "task": task.key,
        "run": run_index,
        "goal": task.goal,
        "session_id": None,
        "watch_url": None,
        "passed": False,
        "error": None,
    }
    try:
        result = await run_goal(
            task.goal,
            base_url=base_url,
            model=model,
            max_turns=max_turns,
            verbose=verbose,
        )
        rec["session_id"] = result.session_id
        rec["watch_url"] = result.watch_url
        state = await fetch_state(http, base_url, result.session_id)

        cr = T.check(task, state)
        rec["passed"] = cr.passed
        rec["check"] = cr.to_dict()
        rec["server"] = server_metrics(state)
        rec["agent"] = agent_metrics(result.tool_calls)
        # Full-fidelity trace (not just counts). The agent-side `input` is the
        # ONLY record of read args (query_suppliers never hits reduce/2); the
        # server log is the authoritative record of mutations + refusals. Final
        # text is neither — it's narration and not guaranteed to match.
        rec["trace"] = {
            "tool_calls": result.tool_calls,  # agent-side: name + actual args sent
            "server_log": state.get("log", []),  # server-side: mutations + refusals
        }
        rec["run_meta"] = {
            "num_turns": result.num_turns,
            "duration_ms": result.duration_ms,
            "total_cost_usd": result.total_cost_usd,
            "is_error": result.is_error,
        }
        rec["final_text"] = result.final_text

        rec["judge"] = None
        if judge and task.judge_rationale and cr.rationale_text and api_key:
            sid_expected = next(iter(task.expected))  # the single escalated id
            supplier = next(
                (s for s in state["suppliers"] if s["id"] == sid_expected), {}
            )
            rec["judge"] = await judge_rationale(
                http, judge_model, api_key, supplier, cr.rationale_text
            )
    except Exception as exc:
        rec["error"] = f"{type(exc).__name__}: {exc}"
        # leave default metric blocks absent; aggregate() skips errored runs
    return rec


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


async def amain(args: argparse.Namespace) -> int:
    # Lazy import so the pure helpers above stay importable without the SDK.
    from agent import run_goal  # noqa: F401

    all_tasks = T.build_tasks()
    if args.task:
        wanted = set(args.task)
        all_tasks = [t for t in all_tasks if t.key in wanted]
        if not all_tasks:
            print(
                f"No tasks match {sorted(wanted)}; known: {[t.key for t in T.build_tasks()]}"
            )
            return 2

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    judge = args.judge and bool(api_key)
    if args.judge and not api_key:
        print("[judge disabled] ANTHROPIC_API_KEY not set\n")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = (
        Path(args.out)
        if args.out
        else (Path(__file__).resolve().parent / "results" / stamp)
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    summaries: list[dict] = []
    async with httpx.AsyncClient() as http:
        for task in all_tasks:
            print(f"\n=== {task.key}: {task.goal} ===")
            records: list[dict] = []
            for i in range(1, args.k + 1):
                print(f"  run {i}/{args.k} …", flush=True)
                rec = await run_one(
                    task,
                    i,
                    run_goal=run_goal,
                    http=http,
                    base_url=args.base_url,
                    model=args.model,
                    max_turns=args.max_turns,
                    judge=judge,
                    judge_model=args.judge_model,
                    api_key=api_key,
                    verbose=args.verbose,
                )
                records.append(rec)
                (out_dir / f"{task.key}_run{i:02d}.json").write_text(
                    json.dumps(rec, indent=2), encoding="utf-8"
                )
                if rec["error"]:
                    print(f"     ERROR: {rec['error']}")
                else:
                    tag = "PASS" if rec["passed"] else "FAIL"
                    why = (
                        ""
                        if rec["passed"]
                        else "  (" + "; ".join(rec["check"]["reasons"]) + ")"
                    )
                    print(f"     {tag}{why}")
            summaries.append(aggregate(task.key, records))

    md = to_markdown(summaries, args.k, args.base_url)
    (out_dir / "summary.md").write_text(md, encoding="utf-8")
    (out_dir / "summary.json").write_text(
        json.dumps(summaries, indent=2), encoding="utf-8"
    )
    print("\n" + md)
    print(f"\nArtifacts: {out_dir}")

    all_passed = all(s["pass_rate"] == 1.0 for s in summaries)
    return 0 if all_passed else 1


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run supplier-triage agent evals.")
    p.add_argument(
        "--k",
        type=int,
        default=3,
        help="runs per task (default 3; use 10 for a final pass)",
    )
    p.add_argument(
        "--task",
        action="append",
        help="restrict to task key(s): t1 t2 t3 t4 (repeatable)",
    )
    p.add_argument("--base-url", default=DEFAULT_BASE_URL)
    p.add_argument(
        "--model", default=os.environ.get("TRIAGE_MODEL", "claude-sonnet-4-6")
    )
    p.add_argument("--max-turns", type=int, default=25)
    p.add_argument(
        "--judge",
        dest="judge",
        action="store_true",
        default=True,
        help="score task-3 rationale (default on)",
    )
    p.add_argument("--no-judge", dest="judge", action="store_false")
    p.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL)
    p.add_argument(
        "--out", default=None, help="output dir (default evals/results/<timestamp>)"
    )
    p.add_argument(
        "--verbose", action="store_true", help="stream agent text/tool calls per run"
    )
    # allow comma lists too: --task t1,t3
    ns = p.parse_args(argv)
    if ns.task:
        flat: list[str] = []
        for item in ns.task:
            flat.extend(part for part in item.split(",") if part)
        ns.task = flat
    return ns


if __name__ == "__main__":
    raise SystemExit(asyncio.run(amain(parse_args())))

