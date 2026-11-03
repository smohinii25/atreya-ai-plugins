# Safety rules (plain English)

`hooks/guard.sh` checks every tool call before it runs. If the guard fails or
cannot understand a call, the call is blocked (fail-closed). A blocked call
says which rule stopped it, e.g. `BLOCKED [repo-write]`. Paths are relative to
the `workspace_root` setting.

## a. Secret files: never read
Blocked for Read, Grep, Glob, Bash (and Edit/Write): `.env`, `.env.*`, `*.jks`,
`*.keystore`, `firebase-*.json`, `google-services.json`,
`GoogleService-Info.plist`, `gchat_logger.dart`, `flavor_config.dart`,
`SamvitPaymentBridgeController.php` (live Razorpay credentials found by the
secret scan). Only `.env.example` is allowed.
- `flavor_config.dart` holds the app's baseUrl next to payment keys. Only one
  tested script, `scripts/extract-baseurl.sh`, reads it; it prints just the
  redacted https baseUrl per environment. Claude never reads, cats or greps it.
- All other plugin scripts read repo files only through `tracked_files`
  (`scripts/lib/common.sh`), which leaves secret files out.
- Script output that copies text out of repo files passes the shared redaction
  filter (`scripts/lib/redact.sh`: Razorpay, AWS, Google, Stripe-style keys,
  private key blocks, and values assigned to names containing
  key/secret/token/password). Scripts that write only names, counts and
  `file:line`, or combine already-redacted `_map` data, do not copy values.
  Nothing in `atreya-docs/` may contain a key.
- Many of these files are committed to git, so git commands that print file
  contents (`git show`, `git diff`, `git log -p`, `git grep`) need
  `-- <path>` that leaves out secret files, or a names-only flag
  (`--stat`, `--name-only`, `-l`).
- Searching file contents in a folder that holds a secret file is blocked.
  Names-only searches (`grep -rl`, `rg -l`, Grep's default mode) always work.
  To see matching lines, search a narrower folder (e.g. `app/`, `routes/`) or
  use Grep with a `glob`/`type` that leaves the secret files out.

## b. repos/ is read-only
No edits, file writes or Bash writes (`>`, `>>`, `tee`, `sed -i`, `mv`, `cp`,
`rm`, `touch`, ...) under `repos/` unless ALL of these are true:
1. `atreya-docs/dev/.active-ticket` names one ticket,
2. `atreya-docs/dev/<ticket>/APPROVED` exists (a human creates it),
3. the repo is on a feature branch, not `master`, `main` or `production`
   (a human creates the branch).

When the current folder is inside `repos/`, output may still be redirected to
`atreya-docs/`, `atreya-qa/` or `/tmp`. `atreya-docs/` and `atreya-qa/` are
always writable.

## c. git: read-only
Allowed: `status`, `diff`, `log`, `show`, `blame`, `branch` (listing only),
`rev-parse`, `ls-files`, `grep`, `remote -v`. Every other git command is
blocked everywhere, including in `atreya-qa/`. A human commits, branches and pushes.

## d. php artisan
Only `route:list`, `list` and `about`.

## e. Package installs
`composer`, `npm`, `yarn`, `pnpm`, `pip`, `flutter pub`/`dart pub`, `pod`
installs and updates are blocked inside `repos/`, even with an approved
ticket. They are allowed in `atreya-qa/`.

## f. Production hosts
The hosts in `config/prod-hosts.txt` and their subdomains are blocked for
Playwright/browser tools, WebFetch, and Bash network commands (`curl`,
`wget`, ...). Staging hosts such as `staging-dashboard.naditarangini.com` are
allowed. Mentioning a host in a code search (`grep`) is fine.

## g. Zoho Sprints
Zoho Sprints tools that read (`Get...`) run normally. Every Zoho Sprints tool
that changes something (create, update, add, move, link, delink, associate,
approve, start/complete/cancel sprint) asks you to confirm first. Write
tools of other Zoho apps are blocked; they are not part of this workflow.

## s. Self-protection
Claude may never create, edit, move, copy or delete a file named `APPROVED`,
the plugin's own files, or Claude Code settings files (`.claude/settings*.json`,
`~/.claude.json`, `~/.claude/plugins/`).

## Docs commands (map, link-apis, prd, brd, diagram, impact, sync)
- They write only to `atreya-docs/`; `repos/` is only read. Scripts read repo
  files only through `tracked_files` (no secret files, no untracked files).
- Three layers keep keys out of docs: script output copied from code passes the
  redaction filter; `check-doc.sh` fails a doc with a key-like string; the
  `doc-checker` agent reports any "Secret risk" by line number, never the value.
- Zoho Sprints is read with **Get** tools only (prd, brd, impact). They never
  create or change items.
- sync uses only `git log` (names and subjects, never file contents). impact
  uses `git ls-files` / `rev-parse` (names and hashes) and the `_map/` data;
  `impact-facts.sh` refuses a secret file as a seed. To prove a "Verified"
  citation, `impact-render.sh` / `impact-check.sh` read only the cited line of a
  tracked, non-secret file (the same rule as `check-doc.sh`). impact lists
  `atreya-qa/` test files that name a requirement ID by file name only (`.env*`
  skipped, contents never copied).
- impact keeps script facts and Claude's analysis apart in `impact-facts.json`:
  the facts carry a hash; render and check refuse edited facts. The analysis is
  refused (nothing written) if it holds a key-like string (also checked on the
  decoded JSON text), sets a review status, claims a QA result without a QA
  report file, or cites as Verified a line that does not exist.
- `impact-report.html` is one self-contained file: inline CSS/JS only, a CSP of
  `default-src 'none'` (no network request is possible), every value
  HTML-escaped, map data embedded as JSON with `<`, `>`, `&` escaped, no
  `innerHTML`/`eval`. `impact-check.sh` fails the report if its script or style
  differ from the template, if any external URL, injected tag or inline event
  handler appears, or if it is not marked Draft.
- Only a human moves a doc from Draft to Reviewed/Approved, approves
  `modules.yaml`, and fills `environments.md`.

## Known limits
- **Grep gap:** the guard finds secret files by name in the searched folder.
  To also have Claude Code itself refuse them, add to `~/.claude/settings.json`:
  `"permissions": {"deny": ["Read(**/.env)", "Read(**/.env.*)", "Read(**/*.jks)", "Read(**/*.keystore)", "Read(**/firebase-*.json)", "Read(**/google-services.json)", "Read(**/GoogleService-Info.plist)", "Read(**/gchat_logger.dart)", "Read(**/flavor_config.dart)"]}`
  (this also stops `.env.example`, so add only if that is acceptable).
- Scripts are invisible to the guard: it sees `bash script.sh`, not what the
  script reads. The plugin's own scripts are tested (tests/scripts-tests.sh) to
  never output secret-file contents; a script someone writes ad hoc is not.
- Files written by programs the guard cannot look inside (`npm run build`,
  `flutter build`, `bash script.sh`) are not detected. Inline code
  (`python -c`, `node -e`, `php -r`) is blocked when the current folder is in `repos/`.
- For `git ... -- <path>`, secrets are checked against files git tracks now,
  not ones that existed only in older history.
- If the guard ever exceeds its 30 s timeout, Claude Code does not block the call.
  The guard refuses very broad searches (`/`, `$HOME`) to stay fast.
- Committed `.env`/firebase keys are an exposure outside Claude too; rotate them
  and remove them from git history (a human task).
