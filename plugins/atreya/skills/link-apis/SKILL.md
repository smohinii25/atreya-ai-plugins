---
name: link-apis
description: Link every Frontend page and App screen to the backend API it calls (method + endpoint → route → controller@method → models/tables), list calls with no matching route and routes no screen calls, and refresh the link-apis block in not-in-use.md. Run as /atreya:link-apis [module-id].
argument-hint: "[module-id]"
model: sonnet
effort: low
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/*), Read
---

Arguments: `$ARGUMENTS` (optional module id from `atreya-docs/modules.yaml`).
Workspace root: `${user_config.workspace_root}`; pass it as `--root` to every script.
The scripts do all the work; do not read raw `_map/*.json` into the conversation.

1. Check `atreya-docs/modules.yaml` exists; if not, tell the user to run
   `/atreya:map --merge` first and stop.
2. For each client repo (every repo under `repos/` except the `backend:` named in
   modules.yaml), run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/calls.sh" --root "${user_config.workspace_root}" <repo>`.
   If it says "run controllers.sh first", run `/atreya:map <repo>` steps first.
3. Run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/link-apis.sh" --root "${user_config.workspace_root}" --update-not-in-use`
   adding `--module <id>` when a module id was given.
   `--update-not-in-use` only replaces the block between `<!-- link-apis:start -->`
   and `<!-- link-apis:end -->` in not-in-use.md; everything else stays as written.
4. Report, using the script's summary lines:
   - per client: calls, matched (with a page / without), method mismatch, no
     route, unresolved, overrides applied / unused;
   - backend: routes called by a screen / total;
   - for the module (if given): its routes called / not called, and its calls;
   - the "calls with no matching route" rows (they are likely bugs or removed
     endpoints) from `_map/<client>/api-links.md`, at most 15, with file:line.
   Point to `_map/<client>/api-links.md` and `_map/<backend>/api-links.md` for the full tables.
5. Remind the user that "not called" for modules marked *external callers*
   (other products, partner API) is expected: their clients are not in this workspace.
6. Pages are credited from code only: the view a call renders, page JS and forms
   that reach its Frontend route (a JS file several pages load counts only for
   the pages that have its element or call its function), and for the App the
   screen that sends the bloc event / calls the method behind the call. Anything
   else is "unresolved" with a reason, never credited to every page. Show the
   count of "Calls with no page" and any "Overrides that match nothing", and tell
   the user they can fix a call by hand in `atreya-docs/_map/overrides.yaml`
   (source = the call site listed). Never edit overrides.yaml yourself.
