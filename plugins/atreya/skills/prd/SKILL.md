---
name: prd
description: Draft or update the PRD of one module from code (and optionally a Zoho Sprints item) into atreya-docs/nt/<module>/PRD.md, with <MODULE>-Rnn requirements, environment matrix, staging delta and a doc-checker report. Run as /atreya:prd <module-id> [zoho-sprints-item-id].
argument-hint: "<module-id> [zoho-sprints-item-id]"
model: sonnet
effort: medium
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit
---

Arguments: `$ARGUMENTS`. Workspace root: `${user_config.workspace_root}` (pass as
`--root`). Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`. Follow
`${CLAUDE_PLUGIN_ROOT}/references/prd-guide.md` and
`${CLAUDE_PLUGIN_ROOT}/references/doc-control.md`. Never invent: cite or ask.

1. **Facts.** Run `module-facts.sh <id>` and `staging-delta.sh <id>`. If the module is
   unknown, stop and list valid ids from `atreya-docs/modules.yaml`. Read
   `atreya-docs/_map/_modules/<id>/facts.md` and `references/prd-template.md`.
2. **Ticket (optional).** If a Zoho Sprints item id was given, read it with Zoho
   Sprints **Get** tools only (e.g. GetItemDetails); cite it as `Zoho Sprints <id>`.
   Never call a non-Get Zoho tool here.
3. **Existing PRD.** If `atreya-docs/nt/<id>/PRD.md` exists, read it and keep its
   requirement IDs (prd-guide "If PRD.md already exists"). Tell the user the new
   draft resets status to Draft.
4. **Write** `atreya-docs/nt/<id>/PRD.md`: front matter from `doc-stamp.sh <id> PRD`,
   then the 15 sections. Read cited code only where the fact pack is not enough,
   in single files or narrow folders.
5. **Lint** with `check-doc.sh atreya-docs/nt/<id>/PRD.md`; fix and re-run until PASS.
6. **Independent check.** Launch the `doc-checker` agent (fresh context) with the
   PRD path and the workspace root. Save its report as
   `atreya-docs/nt/<id>/checks/PRD-check.md`. Fix every Mismatch (correct it or
   move it to §13) and every Not provable (add a citation or move it to §13);
   re-run `check-doc.sh`.
7. **Critical modules** (`critical: true` in the fact pack: nadi-flow, payments,
   ENACH): run the doc-checker a second time on the fixed draft
   (`checks/PRD-check-2.md`), then list every §13 item to the user and **wait for a
   decision on each** before calling the PRD done.
8. **Report**: requirement count, open questions count, check-doc result,
   doc-checker summary line, files written. Do not change `doc_status` in
   modules.yaml (human-owned).
