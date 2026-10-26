# atreya-ai-plugins

Claude Code marketplace for Atreya Innovations. It holds one plugin, **atreya**
(commands appear as `/atreya:<name>`). Version 0.1.0 is phase 1: a fail-closed
safety guard, a session banner and `/atreya:help`. The docs, QA and dev
commands listed by `/atreya:help` come in later phases.

## What the guard protects

Your workspace (the `workspace_root` setting) is laid out like this:

```
<workspace_root>/
  repos/        product repos      read-only by default
  atreya-docs/  docs, QA, dev output   writable
  atreya-qa/    Playwright tests   writable
```

Every tool call is checked before it runs:
- secret files (`.env`, keystores, firebase/google-services files, ...) are never read;
- `repos/` is read-only unless a human-approved ticket and a feature branch exist;
- git is read-only;
- `php artisan` is limited to `route:list`, `list` and `about`;
- package installs are blocked in `repos/`;
- production hosts are blocked;
- Zoho Sprints changes ask you first.

Plain-English rules and known limits:
[`plugins/atreya/references/safety-rules.md`](plugins/atreya/references/safety-rules.md).

## Requirements

- macOS 15 or later (the guard uses the built-in `/usr/bin/jq` and `/bin/bash`; nothing to install)
- Claude Code (terminal, desktop app or VS Code)
- Access to the GitHub repo `smohinii25/atreya-ai-plugins`. If it is private, sign
  in first with `gh auth login` (or have an SSH key for github.com); Claude Code
  uses your existing git credentials and never prompts.

## Install (each teammate, once)

In a Claude Code session:

```
/plugin marketplace add smohinii25/atreya-ai-plugins
/plugin install atreya@atreya-ai-plugins
```

Choose **Install for you (user scope)**. Or, from your shell:

```bash
claude plugin install atreya --marketplace smohinii25/atreya-ai-plugins
```

When the plugin is enabled, Claude Code asks for its settings:

| Setting | What to enter |
|---|---|
| `workspace_root` | **Your own** workspace folder, e.g. `/Users/<you>/Mohini/atreya-ai` (default `~/Mohini/atreya-ai`) |
| `staging_url` | Staging dashboard (default `https://staging-dashboard.naditarangini.com`) |
| `staging_username` | Your staging QA login |
| `staging_password` | Your staging password. Stored in the macOS Keychain, not in `settings.json` |

## Set or change `workspace_root`

Run `/plugin`, open the **Installed** tab, select **atreya** and choose
**Configure options**. Non-sensitive settings also appear in `/config`.
Then start a new session (or run `/reload-plugins`).

Check it: every session starts with a banner such as

```
atreya v0.1.0 | workspace ~/Mohini/atreya-ai | repos read-only
```

If the path is wrong, the banner says `NOT FOUND`. Run `/atreya:help` to see
the commands.

## Run the guard tests

From a clone of this repo:

```bash
git clone https://github.com/smohinii25/atreya-ai-plugins.git
cd atreya-ai-plugins
bash plugins/atreya/tests/guard-tests.sh       # PASS/FAIL per case + summary
bash plugins/atreya/tests/guard-tests.sh -v    # also print each block reason
claude plugin validate plugins/atreya
```

The tests build a throwaway workspace in `$TMPDIR` (fake repos, dummy secrets,
an approved ticket) and delete it afterwards; they never touch your real repos.
The script exits with 1 if any case fails.

## Updates

Auto-update is off by default for this marketplace. To update: `/plugin`, then
**Marketplaces**, then **atreya-ai-plugins**, then **Update marketplace**. Or run
`claude plugin update atreya@atreya-ai-plugins`. You can also turn on
**Enable auto-update** there.

## For maintainers

- `plugin.json` pins `version`, so bump it (e.g. 0.1.1) on every change or
  teammates will not receive the update.
- Production hosts live in `plugins/atreya/config/prod-hosts.txt`, one per
  line. Never add a parent domain such as `naditarangini.com`, because it
  would also block staging.
- Run `guard-tests.sh` and `claude plugin validate plugins/atreya` before every push.
- The guard blocks edits to the plugin folder it is loaded from. If you test
  with `claude --plugin-dir plugins/atreya`, edit the files in a session where
  the plugin is not loaded.
