---
name: help
description: List the atreya plugin commands (docs, QA and dev workflow) and the safety rules that protect the workspace.
model: haiku
disable-model-invocation: true
---

Print the text below to the user exactly as written. Do not run any tools,
add commentary, or offer to run anything.

---

**atreya v0.1.0** · workspace `${user_config.workspace_root}` · repos read-only

**Docs** – available (write only to `atreya-docs/`; every statement cites code
or goes to "Needs confirmation")
- `/atreya:map <repo>` – map a repo: routes, controllers, tables, screens, external systems
- `/atreya:map --merge` – propose the module list; writes `modules.yaml` after your approval
- `/atreya:link-apis [module]` – link each page/screen to the backend API it calls
- `/atreya:prd <module> [zoho-item]` – draft or update a module's PRD (+ doc-checker report)
- `/atreya:brd <module> [zoho-item]` – draft or update a module's BRD in plain language
- `/atreya:diagram <module> [er|flow|sequence|all]` – draw.io diagrams generated from code
- `/atreya:impact <zoho-item | "free text">` – impact of one change: modules, APIs, screens, docs, risk, QA to rerun
- `/atreya:sync [module]` – list docs and diagrams that are out of date with the code; refresh the ones you approve

Typical order: `map` each repo → `map --merge` → `link-apis` → `prd` → `brd` →
`diagram`; then `impact` per ticket and `sync` after code changes.

**QA** – planned, not available yet (web staging only, tests in `atreya-qa/`)
- `/atreya:cases` – write test cases in the workbook format
- `/atreya:automate` – turn test cases into Playwright tests
- `/atreya:sanity` – run a sanity pass on staging
- `/atreya:regression` – run a regression pass on staging
- `/atreya:report` – write the QA report
- `/atreya:retest` – retest a fixed bug

**Dev** – planned, not available yet (Zoho Sprints tickets; repo writes need an APPROVED ticket)
- `/atreya:task` – pick up a Zoho Sprints task
- `/atreya:bug` – log a bug in Zoho Sprints
- `/atreya:implement` – implement an approved ticket on its feature branch
- `/atreya:review` – review the change
- `/atreya:handoff` – write the handoff note

**Always on:** secret files blocked · git read-only · production hosts
blocked · Zoho Sprints changes need your confirmation (docs commands only read
Zoho). Details:
`${CLAUDE_PLUGIN_ROOT}/references/safety-rules.md`
