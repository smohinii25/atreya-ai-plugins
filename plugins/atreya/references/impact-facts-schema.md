# impact-facts.json (schema `atreya.impact/2`)

The single structured source of one impact run (`atreya-docs/dev/<ticket>/`).
`impact.md` and `impact-report.html` are both rendered from it by
`scripts/impact-render.sh`; `scripts/impact-check.sh` proves they agree.

Two owners, one file:
- **Script facts**: every key except `analysis` and `review`, written by
  `scripts/impact-facts.sh` from `modules.yaml` and `_map/`. They carry a hash
  (`facts_sha256`); if anyone edits them, render and check refuse. Never edit them.
- **Analysis**: the `analysis` key, written by Claude as
  `dev/<ticket>/.analysis-draft.json` and merged by
  `impact-render.sh --analysis` after validation (`scripts/lib/impact-validate.jq`).
- `review.status` is always `Draft` in generated output; only a human changes it
  (in impact.md's front matter).

## Evidence classes
Every statement, finding and risk carries `"evidence": {"class", "cites", …}`.

| Class | Use when | Required |
|---|---|---|
| `Verified` | You read the code that shows it | `cites`: `Repo:path:line` (lines may be `12,40-55`) that exist at the stamped commit; or `"Zoho Sprints <id>"` for what the Zoho item itself says |
| `Inferred` | It follows from verified facts or a rule | `cites` of what it is derived from: `Repo:path:line`, `facts:<key>` (a top-level key of impact-facts.json) or the Zoho item |
| `Assumption` | Nothing proves it | `assumption: "A1"` naming an entry in `assumptions` |
| `Unknown` | It cannot be known statically | `note`: why |
| `Not affected` | You checked and it is not affected | `note`: what was checked |

A claim the doc-checker cannot confirm from its citation is downgraded or moved to
`open_questions`; never upgrade a class to make a check pass.

## Script facts (read-only)
v1 keys (unchanged): `ticket`, `commits`, `map_behind`, `seeds`, `spans`,
`direct_modules`, `related_modules`, `backend_routes` (with every client
`callers`), `web_routes`, `client_calls`, `screens`, `tables` (`changed`, `read`),
`external_systems`, `docs`, `risk` (v1 level), `qa` (sanity / regression /
not covered).

v2 keys:

| Key | What |
|---|---|
| `schema`, `depth_limit`, `map_features` | version; module hops traced; per repo whether `_map` has services/events (`controllers.sh` `classes`/`events`) |
| `modules[]` | `{id, name, critical, role: direct|indirect, depth, direction: changed|upstream|downstream|both, why[], paths[[edge ids]], evidence}`; v1 related modules the walk did not reach are kept (`evidence.class` Inferred, cite `modules.yaml`) |
| `not_affected[]` | modules investigated and cleared: `{id, checked[], reason, evidence}` |
| `graph` | `nodes[] {id, type, label, module, cite, depth, direction, changed}` and `edges[] {id, from, to, type, cite}`; types: handled_by, calls, uses, listens, reads, writes |
| `code[]` | changed and affected methods: `{method, kind, repo, file, cite, lines, module, role, depth, reads, writes[{table, via, lines}], uses[{class, kind, lines}], transaction}` |
| `events[]` | events the changed code emits, with listeners and their modules |
| `data_flow[]` | reads and writes of the changed code: `{op, table, cite, consumers[], evidence}` |
| `unknowns[]` | `{what, why, where}`; `generic: true` for the standing "state shared outside routes and tables" item |
| `conflicts[]` | conflicting evidence `{what, sources, effect}` (one file owned by two modules, route owner differs between modules.yaml and api-links) |
| `cycles[]`, `truncated[]` | circular paths found (recorded once, not followed); nodes beyond the depth limit |
| `risks[]` | rule-based records `{id: RS-nn, rule, level, reason, consequence, evidence, confidence, modules[]}` (references/impact-risk-rules.md) |
| `risk_overall` | `{level, rules, confidence, confidence_why}` from the script rules |
| `traceability[]` | requirement IDs / BRD rows whose citations point into the changed code `{ref, doc, hits}` |
| `qa_scope` | `modules[] {id, role, routes, pages, app_screens}`; `existing[] {ref, kind, source}`: PRD acceptance criteria and atreya-qa test files naming a traced ID |
| `generated_by`, `facts_sha256`, `review` | provenance; hash of the facts; `{status: "Draft", reviewer, date}` |

## The analysis (`.analysis-draft.json`)
Only these top-level keys; unknown keys are refused. `STMT` = `{"text": "...", "evidence": {...}}`.

```jsonc
{
  "input": {"source": "zoho" | "free-text", "id": "<Zoho item id, = ticket>", "title": "...", "text": "short quote of the ticket / the free text"},
  "requirement": {
    "current":  [STMT],            // how it works today (cite the code)
    "proposed": [STMT],            // what the change asks; empty only if "missing" says why
    "objective": STMT,             // business objective (optional)
    "ambiguities": [{"text": "...", "question": "Q1"}],
    "missing":     [{"text": "...", "question": "Q2"}]
  },
  "summary": {"headline": "one sentence, plain language", "consequences": [STMT]},
  "module_notes": {"<affected module id>": {"description": "...", "why_affected": "...", "functional_impact": [STMT]}},
  "added_modules": [{"id": "<modules.yaml id>", "why": "...", "evidence": {...}}],   // found by hand (cache key, queue...)
  "not_affected": [{"id": "...", "reason": "...", "evidence": {"class": "Not affected", "cites": [], "note": "..."}}],
  "workflow": [{"step": 1, "actor": "...", "module": "...", "screen": "...", "route": "...",
                "before": "...", "after": "...", "on_failure": "what happens if this step fails", "evidence": {...}}],
  "data_fields": [{"table": "...", "field": "...", "change": "...", "calculation": "...", "evidence": {...}}],
  "data_consistency": [{"text": "...", "consequence": "...", "risk": "RS-02", "evidence": {...}}],
  "risks": [{"id": "RA-01", "rule": "FAIL-02", "level": "High", "reason": "...", "consequence": "...",
             "raises": "RS-03", "modules": ["..."], "evidence": {...}}],
  "qa_scenarios": [{"id": "QA-01", "module": "...", "step": 2, "type": "positive|negative|boundary|integration",
                    "title": "...", "expected": "...", "origin": "existing|suggested", "trace": ["AUTH-R02"],
                    "status": "Not run", "evidence": {...}}],
  "traceability": [{"ref": "AUTH-R02", "note": "..."}],
  "open_questions": [{"id": "Q1", "question": "...", "role": "PO|Dev|QA|Owner", "blocks": ["RA-01", "QA-02", "step 3"]}],
  "assumptions": [{"id": "A1", "text": "...", "affects": ["RA-01"]}],
  "actions": [{"text": "...", "role": "PO|Dev|QA|Owner"}]
}
```

Rules the renderer enforces (it writes nothing until all hold):
- `input.source` zoho needs `input.id` = the ticket; free text needs an `adhoc-` ticket.
- Module ids: `module_notes` only for affected modules (facts or `added_modules`);
  `workflow` / `qa_scenarios` may also name investigated-not-affected modules.
  `added_modules` must exist in modules.yaml. `not_affected` must not contradict
  the facts (a module the graph reached is affected; explain it or ask).
- Risks: ids `RA-nn`; rule from impact-risk-rules.md; FAIL-01..04 have fixed
  levels; `raises` must name a script risk and be higher. Never lower a level.
- QA: ids `QA-nn`; status `Not run`, or `Passed`/`Failed`/`Blocked` only with
  `evidence.report` = an existing file under `atreya-docs/` or `atreya-qa/`.
  `origin: existing` must trace to `qa_scope.existing`. Every `trace` /
  `traceability` ref must be in the facts or defined in a module PRD/BRD.
- Ids unique (`Q`, `A`, `QA-`, `RA-`, steps); every cross reference exists.
- No key-like strings anywhere (checked on the decoded text).
