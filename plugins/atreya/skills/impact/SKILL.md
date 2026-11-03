---
name: impact
description: End-to-end functional and technical impact analysis of one change (a Zoho Sprints item or free text) into atreya-docs/dev/<ticket>/ - direct and indirect (upstream/downstream) modules with the cited dependency path, workflow before/after, data flow, evidence-based risk, QA regression scope, open questions - as impact.md plus a self-contained interactive impact-report.html, both rendered from impact-facts.json, with mechanical and doc-checker reports. Run as /atreya:impact <zoho-sprints-item-id | "free text">.
argument-hint: "<zoho-sprints-item-id> | \"<free text>\""
model: opus
effort: high
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Grep, Glob, Write, Edit
---

Arguments: `$ARGUMENTS`. Workspace root: `${user_config.workspace_root}` (pass as
`--root`). Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`. Follow
`${CLAUDE_PLUGIN_ROOT}/references/impact-guide.md`,
`${CLAUDE_PLUGIN_ROOT}/references/impact-facts-schema.md`,
`${CLAUDE_PLUGIN_ROOT}/references/impact-risk-rules.md` and
`${CLAUDE_PLUGIN_ROOT}/references/doc-control.md`. Never invent modules,
dependencies, risk levels or test results: cite, mark the evidence class, or ask.
Repos are read-only; this skill only writes under `atreya-docs/dev/<ticket>/`.

1. **Input.**
   - A Zoho Sprints item id: read it with Zoho Sprints **Get** tools only
     (GetItemDetails, GetItemComments, GetLinkedItems as needed). Never call a
     non-Get Zoho tool. Ticket = the item id (letters, digits, `.`, `_`, `-`).
   - Free text: ticket = `adhoc-<slug>` (3–6 lower-case words of the text, `-`).
   - If `atreya-docs/dev/<ticket>/impact.md` exists, say so and ask whether to
     redo it; stop if not.
2. **Seeds.** Read `atreya-docs/modules.yaml` (module ids and names), then the
   fact pack (`_map/_modules/<id>/facts.md`, run `module-facts.sh <id>` if
   missing) and PRD of the likely modules, and the code the change touches
   (single files or narrow folders; never secret files). Content searches over a
   folder that holds a secret file are blocked: find file names first (Glob, or
   Grep in files mode), then search single files. Choose seeds as the guide says:
   narrow, each with a reason and a `Repo:path:line`.
3. **Facts.** Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/impact-facts.sh" --root "${user_config.workspace_root}" --ticket <ticket> [--depth N] <seeds>`
   (depth = module hops to trace, default 3). On "unknown seed", fix the seed and
   re-run. If it warns that `_map` is behind HEAD, stop and tell the user to run
   `/atreya:map <repo>` first. If an unknown says a repo's map has no services/events
   data, tell the user that services and events are not traced until
   `/atreya:map <repo>` is re-run, and go on. If the risk is TBD (no module
   matched), re-check the seeds. Read `dev/<ticket>/impact-facts.md`. Never edit
   `impact-facts.json` by hand: the script facts carry a hash.
4. **Analysis.** Write `atreya-docs/dev/<ticket>/.analysis-draft.json` exactly as
   `references/impact-facts-schema.md` describes: requirement understanding,
   summary, notes per affected module, workflow steps (before / after / if it
   fails), data fields and calculations, data-consistency notes, extra risks
   (add or raise only, rules FAIL-01..04 or the script rules), QA scenarios
   (positive / negative / boundary / integration; existing vs suggested; status
   "Not run"), traceability, open questions (for a named role), assumptions and
   recommended actions. Every statement carries an evidence class; Verified only
   with a `Repo:path:line` you have read. Plain language first. Never set a
   review status.
5. **Render.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/impact-render.sh" --root "${user_config.workspace_root}" --ticket <ticket> --analysis atreya-docs/dev/<ticket>/.analysis-draft.json`
   (use the full path). It refuses a draft with problems and writes nothing; fix
   each listed problem in the draft and re-run. On success it writes
   `impact.md` and `impact-report.html` from `impact-facts.json`.
6. **Mechanical checks.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/impact-check.sh" --root "${user_config.workspace_root}" --ticket <ticket>`
   (runs check-doc.sh too). Fix every FAIL in the draft, re-render, re-check.
   Fix check-doc WARN lines too: point each citation at the line that shows the
   claim (check-doc proves a line exists, not what it says).
7. **Independent check.** Launch the `doc-checker` agent (fresh context) with the
   impact.md path, the impact-facts.json path and the workspace root. Save the
   output of step 6 under "## Mechanical checks" and the agent's report under
   "## Doc-checker" in `atreya-docs/dev/<ticket>/checks/impact-check.md`. Fix
   every Mismatch and Not provable in the draft (correct it, cite it, lower its
   evidence class, or move it to open questions), then re-render and re-run
   step 6.
8. **Report.** Run step 6 with `--final` (summary; removes the merged draft when
   every check passes) and print its summary: the change,
   the changed module(s), the affected modules (direct, indirect with direction
   and depth), the overall risk with its confidence and rules, the missing
   information (open questions, missing requirements, assumptions, unknowns,
   conflicts), the paths of impact.md and impact-report.html, and the validation
   results (impact-check, check-doc warnings, doc-checker counts). Status stays
   Draft. Do not create tickets or change Zoho.
