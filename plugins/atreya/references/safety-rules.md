# Safety rules (plain English)

`hooks/guard.sh` checks every tool call before it runs. If the guard fails or
cannot understand a call, the call is blocked (fail-closed). A blocked call
says which rule stopped it, e.g. `BLOCKED [repo-write]`. Paths are relative to
the `workspace_root` setting.

## a. Secret files: never read
Blocked for Read, Grep, Glob, Bash (and Edit/Write): `.env`, `.env.*`, `*.jks`,
`*.keystore`, `firebase-*.json`, `google-services.json`,
`GoogleService-Info.plist`, `gchat_logger.dart`. Only `.env.example` is allowed.
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

## Known limits
- **Grep gap:** the guard finds secret files by name in the searched folder.
  To also have Claude Code itself refuse them, add to `~/.claude/settings.json`:
  `"permissions": {"deny": ["Read(**/.env)", "Read(**/.env.*)", "Read(**/*.jks)", "Read(**/*.keystore)", "Read(**/firebase-*.json)", "Read(**/google-services.json)", "Read(**/GoogleService-Info.plist)", "Read(**/gchat_logger.dart)"]}`
  (this also stops `.env.example`, so add only if that is acceptable).
- Files written by programs the guard cannot look inside (`npm run build`,
  `flutter build`, `bash script.sh`) are not detected. Inline code
  (`python -c`, `node -e`, `php -r`) is blocked when the current folder is in `repos/`.
- For `git ... -- <path>`, secrets are checked against files git tracks now,
  not ones that existed only in older history.
- If the guard ever exceeds its 30 s timeout, Claude Code does not block the call.
  The guard refuses very broad searches (`/`, `$HOME`) to stay fast.
- Committed `.env`/firebase keys are an exposure outside Claude too; rotate them
  and remove them from git history (a human task).
