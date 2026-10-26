---
name: map
description: Map one product repo (routes, controllers, models/tables, screens, external systems) into atreya-docs/_map/<repo>/, or with --merge propose the module list and, after approval, write atreya-docs/modules.yaml. Run as /atreya:map <repo> or /atreya:map --merge.
argument-hint: "<repo> | --merge"
model: opus
effort: high
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read
---

Arguments: `$ARGUMENTS`
Workspace root: `${user_config.workspace_root}` (pass it to every script as `--root`).
Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`. Repos are read-only; scripts write only
to `atreya-docs/`. Never read secret files; never paste raw `_map/*.json` into the
conversation (use the scripts' one-line summaries and `jq` queries).

## /atreya:map <repo>
Run these in order with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/<name>" --root "${user_config.workspace_root}" <repo>`
and stop at the first error:
1. `routes.sh`, `models.sh`, `controllers.sh` (Laravel repos only: skip if the repo has no `routes/`)
2. `screens.sh` (Blade repos: also the page JS each page loads and the AJAX calls
   in it), `externals.sh`, `cluster.sh`
3. `routes-crosscheck.sh` (Laravel only, optional; "skipped" is fine)

Then report each script's summary line, and flag: unparsed route lines, controller
files not found, guarded files, screens without a file. Suggest `/atreya:map --merge`
once all three repos are mapped.

## /atreya:map --merge
Follow `${CLAUDE_PLUGIN_ROOT}/references/map-guide.md` exactly. It ends with an
approval step: show the proposed module table and **wait for the user's approval
before writing modules.yaml**.
