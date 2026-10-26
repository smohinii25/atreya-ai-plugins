---
name: impact
description: Impact analysis of one change (a Zoho Sprints item or free text) into atreya-docs/dev/<ticket>/impact.md - affected modules, files, routes, screens, APIs, tables, external systems, docs and diagrams to update, risk level and QA to rerun - with a doc-checker report. Run as /atreya:impact <zoho-sprints-item-id | "free text">.
argument-hint: "<zoho-sprints-item-id> | \"<free text>\""
model: opus
effort: high
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Grep, Glob, Write, Edit
---

Arguments: `$ARGUMENTS`. Workspace root: `${user_config.workspace_root}` (pass as
`--root`). Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`. Follow
`${CLAUDE_PLUGIN_ROOT}/references/impact-guide.md` and
`${CLAUDE_PLUGIN_ROOT}/references/doc-control.md`. Never invent: cite or ask.
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
3. **Facts.** Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/impact-facts.sh" --root "${user_config.workspace_root}" --ticket <ticket> <seeds>`.
   On "unknown seed", fix the seed and re-run. If it warns that `_map` is behind
   HEAD, stop and tell the user to run `/atreya:map <repo>` first. If the risk is
   TBD (no module matched), re-check the seeds. Read `dev/<ticket>/impact-facts.md`.
4. **Write** `atreya-docs/dev/<ticket>/impact.md`: front matter from
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/doc-stamp.sh" --root "${user_config.workspace_root}" "<direct module ids, comma-separated>" impact <ticket>`
   (if no direct module, use the related ones), then the 12 sections of
   `references/impact-template.md` as the guide describes.
5. **Lint** with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-doc.sh" --root "${user_config.workspace_root}" atreya-docs/dev/<ticket>/impact.md`;
   fix until PASS, and fix its WARN lines too (brace-only lines, citations
   without the repo). check-doc proves a cited line exists and is not blank, not
   that it shows the claim: point each citation at the line that does.
6. **Independent check.** Launch the `doc-checker` agent (fresh context) with the
   impact.md path and the workspace root. Save its report as
   `atreya-docs/dev/<ticket>/checks/impact-check.md`. Fix every Mismatch and Not
   provable (correct, cite, or move to §11); re-run `check-doc.sh`.
7. **Report**: risk level with its signals; direct and related modules; docs and
   diagrams to update; QA sanity / regression and what QA cannot cover; §11
   count; check results; files written. Do not create tickets or change Zoho.
