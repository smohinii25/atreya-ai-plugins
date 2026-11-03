# Impact guide

Input: one change, as a Zoho Sprints item (read with **Get** tools only) or free
text. Output in `atreya-docs/dev/<ticket>/` (free text: `dev/adhoc-<slug>/`):

| File | Written by |
|---|---|
| `impact-facts.json` | `scripts/impact-facts.sh` (facts) + `scripts/impact-render.sh` (merges Claude's analysis) — the single source |
| `impact-facts.md` | `scripts/impact-facts.sh`: the facts, readable |
| `impact.md` | `scripts/impact-render.sh`, from impact-facts.json, in the 12 headings of `references/impact-template.md` |
| `impact-report.html` | `scripts/impact-render.sh`, from the same JSON: one self-contained interactive page |
| `checks/impact-check.md` | Claude: output of `impact-check.sh` + the doc-checker agent's report |

An impact doc describes one change at one moment; `/atreya:sync` does not track it.
Schema: `references/impact-facts-schema.md`. Risk rules: `references/impact-risk-rules.md`.

## How it is built
1. **Seeds (Claude).** Decide what the change touches, from the ticket and the
   code. Each seed needs a reason you can cite:
   - `--file Repo:path:line` a line inside the method that changes (the script
     widens it to the whole method and the routes that call it); `--file Repo:path`
     only when the whole file changes; a service, job or listener file works the
     same way (its users are found);
   - `--route "METHOD uri"` a backend route whose behaviour changes;
   - `--table name` only when a table's **structure or meaning** changes (new or
     changed column, new allowed value) — not because the code reads or writes it;
   - `--screen Repo:ScreenId`, `--module id` (a module changed as a whole).
   Start narrow: seed the code that must change, not everything nearby. Do not
   seed the callers: the script finds them.
2. **Facts (script).** `impact-facts.sh` derives everything else from
   modules.yaml and `_map/` (below), applies the risk rules and the QA scope. It
   refuses unknown seeds and secret files. It sees code, routes, tables, screens,
   services, events and listeners. It does **not** see state shared another way:
   cache keys, session keys, queues, files on S3, scheduled jobs. Check those by
   hand in the changed methods and add what you find as `added_modules` (with a
   citation) or as an open question.
3. **Analysis (Claude).** Write `.analysis-draft.json` (schema file): requirement
   understanding, workflow, module notes, data, extra risks, QA scenarios, open
   questions. Every statement carries an evidence class; Verified only with a
   citation you have read. Never invent a fix: describe what is affected, not how
   to implement it, unless the ticket says so.
4. **Render, check, verify.** `impact-render.sh --analysis` validates and merges
   the draft, then renders impact.md and impact-report.html; `impact-check.sh`
   proves they agree with the JSON and that the HTML is safe; the doc-checker agent
   re-reads the cited code in a fresh context.

## Indirect dependencies (scripts/lib/impact-graph.jq)
The script walks a graph built from `_map/` (every edge cites `Repo:path:line`):

| Edge | From | Walk direction |
|---|---|---|
| route → method (handled_by) | routes.json | the change in a method reaches its routes (**upstream**) |
| client caller → route (calls) | api-links.json | a changed route reaches every web/app caller (**upstream**) |
| method → class (uses) | controllers.json `uses` | a changed service/job/listener reaches the methods that use it (**upstream**) |
| method → table (reads/writes) | controllers.json | a **changed** table reaches the methods that read or write it (**downstream**) |
| method → listener (listens) | `events` (EventServiceProvider) | a changed method reaches the listeners of the events it emits (**downstream**) |
| changed client code → route (calls) | api-links.json | the route it calls (**downstream**, not followed further) |

- **Direct** = owns changed code. **Indirect** = reached by the walk, with the
  shortest cited path as "why". **Upstream** = calls into the changed code;
  **downstream** = the change flows into it (data, events, calls it makes); once a
  path goes downstream it stays downstream; reached both ways = **both**.
- **Depth** = module hops from the change (entering another module = +1), limit
  `--depth` (1–5, default 3). Nodes beyond it are listed, not followed.
- **Cycles**: a node already on the current path is recorded once and not followed.
- **Not traced**, listed under "investigated, not affected" with the reason:
  modules that only read the tables the changed code reads; readers of tables the
  changed code writes without changing their structure or meaning (seed `--table`
  if the values written change); owners of services the changed code calls.
- **Unknown**: a repo whose `_map` has no services/events yet (mapped before this feature; re-run `/atreya:map`), changed routes no
  client in the workspace calls, unresolved API calls in changed code, writes whose
  model cannot be resolved, events without a mapped listener, and always the state
  shared outside routes and tables.
- **Conflicting evidence**: a changed file owned by two modules, a route claimed by
  two modules, or a route's module differing between modules.yaml and api-links.
  Conflicts make the overall confidence Low.

## Sections of impact.md (and the matching parts of impact-report.html)
1. **Change**: source, ticket, the request quoted; what is asked; *Requirement
   understanding*: current and proposed behaviour, business objective,
   ambiguities and missing requirements (each linked to a question).
2. **Summary**: changed module(s), direct / indirect / not-affected counts, overall
   risk and confidence, key business consequences.
3. **Affected modules**: Direct; Indirect (depth, direction, cited path);
   Investigated, not affected; *End-to-end workflow*: actor, module, screen/route,
   before, after, what happens if the step fails.
4. **Code**: backend routes changed with every client caller; web routes; API calls
   from changed client code; changed and affected methods (reads, writes, uses,
   transaction); events; cycles and depth limit.
5. **Screens**: web pages and app screens that show or call the changed code.
6. **Data**: tables changed / read; data flow; fields and calculations;
   data-consistency and financial risks.
7. **External systems** used inside the changed code.
8. **Docs & diagrams to update**: from the facts' docs scan. A hit marked "(route
   line only)" means the doc lists the route; update it only if the route itself
   changes (URI, method, middleware). Also search the modules' open questions
   (PRD §13, BRD §12) for the change's key words: the change may answer one of
   them. *Traceability*: requirement IDs / BRD rows citing the changed code.
9. **Risk**: overall level, confidence, every record with rule, reason,
   consequence, evidence and source; the v1 level for continuity. If the level
   depends on an open decision, add an `RA` record with the higher level and link
   the question (`blocks`).
10. **QA to rerun**: v1 sanity / regression / not covered; scope by module (pages,
    app screens, scenarios); scenarios (type, origin, trace, status "Not run");
    existing tests and acceptance criteria; limits from
    `references/qa-scope-rules.md` (e.g. OTP steps are skipped: no real OTP codes).
11. **Needs confirmation**: open questions for a named role, assumptions, unknowns,
    conflicting evidence, recommended actions.
12. **Document control**: status Draft until a human changes it; facts hash; checks.

## v1 risk rules (still computed as "v1 rule level")
- **High** if any of: a critical module is directly changed; Razorpay or ENACH code
  is inside the changed code; a changed table is used by 3 or more modules; 4 or
  more modules are directly changed.
- **Medium** if any of: 2–3 modules directly changed; a changed backend route is
  called by both web and app; a changed table is shared by 2 modules; the changed
  code uses any external system.
- **Low** otherwise. **TBD** when the seeds match no module (check the seeds).

## QA rules (web staging only, references/qa-scope-rules.md)
- **Sanity**: directly changed modules that have web pages, with the pages.
- **Regression**: sanity + related modules that have web pages.
- **Not covered by QA**: modules with no web pages (app or backend only) and the
  app screens affected — list them so the developer tests them.
- Nothing is "executed" by an impact analysis: every scenario is `Not run` unless a
  QA report file is cited.
