---
name: sync
description: Find the docs and diagrams that are out of date with the code (each doc's commit stamp compared with HEAD for the module's files), then refresh only the ones the user approves. Run as /atreya:sync [module-id].
argument-hint: "[module-id]"
model: haiku
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read
---

Arguments: `$ARGUMENTS` (optional module id). Workspace root:
`${user_config.workspace_root}`; pass it as `--root` to every script. Never edit a
doc or diagram by hand; never write anything without the user's approval.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" --root "${user_config.workspace_root}"`
   (add `--module <id>` if given). Show the user its output: one line per doc
   (STALE / CHECK / OK / UNKNOWN), the commits and files behind each, and the
   summary line. If every doc is OK, say so and stop.
2. If it warns that `_map` is behind HEAD, tell the user to run
   `/atreya:map <repo>` for those repos before any refresh, and stop: a refresh
   now would use old map data.
3. Ask the user which STALE / CHECK / UNKNOWN docs to refresh (CHECK means only
   shared files changed: the doc may still be right). Refresh only the approved ones:
   - diagram: run `module-facts.sh <id>` once for the module, then
     `make-diagram.sh <id> --rerun <name>` (it must end with `check-doc: PASS`).
     If it fails (no saved options, or a route no longer exists), report it and
     suggest `/atreya:diagram <id>`.
   - staging-delta: run `staging-delta.sh <id>`.
   - PRD / BRD: do not draft them here. Give the user the command to run:
     `/atreya:prd <id>` then `/atreya:brd <id>` (they keep IDs and run the doc-checker).
4. Re-run `sync.sh` and report the new status of each doc: refreshed, still stale
   (with the command to run), or skipped by the user. Refreshed diagrams have not
   had a new doc-checker pass: suggest `/atreya:diagram <id>` for one.
