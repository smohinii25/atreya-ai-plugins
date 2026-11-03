# Changelog (atreya plugin)

## 0.2.0 — 2026-11-03

`/atreya:impact` is now an end-to-end functional and technical impact analysis.
The command, its arguments, `impact.md` (same 12 headings) and the
`dev/<ticket>/` / `dev/adhoc-<slug>/` layout are unchanged.

### Added
- **Indirect dependencies.** `impact-facts.sh` traces the change through:
  - routes → web/app callers;
  - shared services, jobs and listeners;
  - changed tables → their readers and writers;
  - emitted events → listeners.

  Each module has a depth (`--depth`, default 3), upstream/downstream/both, and
  the cited path. Cycles are recorded, not followed. Modules beyond the limit are
  listed. Investigated-but-not-affected modules come with the reason. Unknown
  links and conflicting evidence are listed (`scripts/lib/impact-graph.jq`).
- **Rule-based risk.** `references/impact-risk-rules.md` and
  `scripts/lib/impact-risk.jq` cover money and data integrity, security,
  dependency count, business criticality and failure consequence. Levels run
  Critical/High/Medium/Low, and each record has a reason, consequence, evidence
  and confidence. Name patterns live in `config/impact-signals.yaml`.
- **Evidence classes** on every finding: Verified, Inferred, Assumption,
  Unknown, Not affected (`references/impact-facts-schema.md`).
- **`impact-facts.json` (schema `atreya.impact/2`)** as the single source.
  Script facts are hashed; Claude's analysis is merged under `analysis` after
  validation. The analysis covers requirement understanding, workflow steps
  (before/after/if it fails), module notes, data fields, data-consistency
  notes, extra risks (add or raise only), QA scenarios (never "executed"
  without a report), traceability, open questions, assumptions and actions.
- **`scripts/impact-render.sh`** renders `impact.md` and the new
  **`impact-report.html`** from the JSON. The HTML is one self-contained
  offline file with a dependency map, search and filters, drill-downs, and
  print and mobile layouts. All text is escaped and a CSP blocks requests.
- **`scripts/impact-check.sh`** checks:
  - the facts hash, and Draft status in JSON, Markdown and HTML;
  - that Markdown and HTML show the same IDs and counts as the JSON;
  - HTML safety, and secrets;
  - check-doc.

  `--summary` / `--final` print the end-of-run summary.
- **`controllers.sh`** adds new fields only: per method `uses` (services, jobs,
  events), `writes` (tables) and `transaction`; plus `classes` (other app
  classes) and `events` (EventServiceProvider `$listen`). A map built before
  this upgrade still works: services/events show as Unknown until `/atreya:map`
  is re-run. `$var->save()/update()/delete()` resolves to the model `$var` was
  assigned from (`new X`, `X::find…`) or type-hinted as; otherwise the table is
  "?" and listed as Unknown. App\Facades and App\Actions classes get their own kind.
- **Tests:**
  - `tests/impact-tests.sh` (fake fixtures in `tests/fixtures/impact/`);
  - `tests/compat-otp-example.sh` (the real `adhoc-otp-attempt-limit` example
    gives the same modules, routes and callers as before).

### Changed
- The impact skill: new run order (facts → analysis draft → render →
  impact-check → doc-checker → summary). Still opus/high.
- The `doc-checker` agent (still sonnet, read-only) also checks evidence
  classes, indirect paths, not-affected reasons, workflow steps and risk rules
  for impact analyses.
- Docs: `impact-guide.md`, `doc-control.md` (evidence classes),
  `docs-layout.md`, `safety-rules.md`, README, `/atreya:help`.

### Fixed
- `.claude-plugin/marketplace.json` is back at the repo root (it had been moved
  to `!!.claude-plugin/`, which broke `/plugin marketplace add`).
- `known-answers-auth.sh` and `compat-otp-example.sh` say how to pass the
  workspace root when they skip.

### Compatibility
- Every v1 key of `impact-facts.json` keeps its name and meaning. The v1 risk
  level is still computed and shown as "v1 rule level". The new overall level
  can be higher; the OTP example's is High (SEC-01) while its v1 level stays
  Medium.

## 0.1.0 — first release
- Fail-closed safety guard, session banner, `/atreya:help`; docs commands map,
  link-apis, prd, brd, diagram, impact, sync.
