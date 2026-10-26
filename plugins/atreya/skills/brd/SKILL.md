---
name: brd
description: Draft or update the business requirements document (BRD) of one module, in plain language for non-technical readers, into atreya-docs/nt/<module>/BRD.md with BR-nn requirements and a doc-checker report. Run as /atreya:brd <module-id> [zoho-sprints-item-id].
argument-hint: "<module-id> [zoho-sprints-item-id]"
model: sonnet
effort: medium
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read, Write, Edit
---

Arguments: `$ARGUMENTS`. Workspace root: `${user_config.workspace_root}` (pass as
`--root`). Follow `${CLAUDE_PLUGIN_ROOT}/references/brd-guide.md` and
`${CLAUDE_PLUGIN_ROOT}/references/doc-control.md`. Never invent: cite or ask.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/module-facts.sh" --root "${user_config.workspace_root}" <id>`.
   Read `atreya-docs/_map/_modules/<id>/facts.md`, `references/brd-template.md`,
   and `atreya-docs/nt/<id>/PRD.md` if it exists (reuse its IDs as sources).
2. If a Zoho Sprints item id was given, read it with Zoho Sprints **Get** tools only.
3. If `atreya-docs/nt/<id>/BRD.md` exists, keep its BR IDs (never renumber).
4. Write `atreya-docs/nt/<id>/BRD.md`: stamp from `doc-stamp.sh <id> BRD`, then the
   13 sections in plain language; evidence only in Source columns.
5. Run `check-doc.sh atreya-docs/nt/<id>/BRD.md` until PASS.
6. Launch the `doc-checker` agent on the BRD; save `checks/BRD-check.md`; fix
   Mismatch / Not provable items (correct, cite, or move to §12); re-run check-doc.
7. Critical modules: second doc-checker pass (`checks/BRD-check-2.md`), then list
   every §12 item to the user and wait for a decision on each.
8. Report: BR count, Needs-confirmation count, check results, files written.
