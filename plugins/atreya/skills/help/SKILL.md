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

Phase 1 is installed: safety guard + this help. The commands below are
**planned** and not available yet.

**Docs** (write to `atreya-docs/`)
- `/atreya:map` – map a repo's modules and screens
- `/atreya:link-apis` – link screens to the backend APIs they call
- `/atreya:prd` – draft a PRD from the template
- `/atreya:brd` – draft a BRD from the template
- `/atreya:diagram` – draw a flow or architecture diagram
- `/atreya:impact` – impact analysis for a change or ticket
- `/atreya:sync` – refresh docs after code changes

**QA** (web staging only, tests in `atreya-qa/`)
- `/atreya:cases` – write test cases in the workbook format
- `/atreya:automate` – turn test cases into Playwright tests
- `/atreya:sanity` – run a sanity pass on staging
- `/atreya:regression` – run a regression pass on staging
- `/atreya:report` – write the QA report
- `/atreya:retest` – retest a fixed bug

**Dev** (Zoho Sprints tickets; repo writes need an APPROVED ticket)
- `/atreya:task` – pick up a Zoho Sprints task
- `/atreya:bug` – log a bug in Zoho Sprints
- `/atreya:implement` – implement an approved ticket on its feature branch
- `/atreya:review` – review the change
- `/atreya:handoff` – write the handoff note

**Always on:** secret files blocked · git read-only · production hosts
blocked · Zoho Sprints changes need your confirmation. Details:
`${CLAUDE_PLUGIN_ROOT}/references/safety-rules.md`
