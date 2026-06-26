# Supplier-triage eval run

_2026-06-25T04:44:22+00:00 · K=3 · server=http://localhost:4000_

| Task | Pass /3 | Pass rate | Actions* | Reviews | Invalid | Tool calls | Reads | Dur (s) | Cost ($) | Judge |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| t1 | 3/3 | 1.00 | 4 | 4 | 0 | 5 | 1 | 23.21 | 0.07 | — |
| t2 | 3/3 | 1.00 | 9 | 9 | 0 | 10 | 1 | 34.41 | 0.08 | — |
| t3 | 3/3 | 1.00 | 1 | 1 | 0 | 2 | 1 | 22.44 | 0.05 | 4.33 |
| t4 | 3/3 | 1.00 | 0 | 0 | 0 | 0 | 0 | 8.20 | 0.01 | — |

*Actions* = mean server-log entries per task (all actions through `reduce/2`, including refused attempts). **Reviews** = mean successful `submit_review`s. **Invalid** = mean log entries with `outcome.status="error"`. **Tool calls / Reads** = agent-side counts (SDK `ToolSearch` excluded). **Judge** = mean rationale-quality score (task 3 only, 1–5, non-gating).
