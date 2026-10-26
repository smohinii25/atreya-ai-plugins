# map --merge guide

Goal: one `atreya-docs/modules.yaml` where **every backend route belongs to exactly
one module or is listed as unassigned**, with a coverage count. Claude decides only
the module *boundaries*; `scripts/build-modules.sh` expands them deterministically.

`S=${CLAUDE_PLUGIN_ROOT}/scripts`, `R=<workspace_root>`, `D=$R/atreya-docs`.

## 1. Check inputs
Every repo under `repos/` must have `$D/_map/<repo>/clusters.json`. If one is
missing, tell the user to run `/atreya:map <repo>` first and stop.

## 2. Read the candidates
Read `$D/_map/*/modules.md` (controller / folder summaries). For a specific question
("which controller serves the prakruti questionnaire?") use the `code-mapper` agent
or a `jq` query on `_map/*.json`; do not read whole JSON files.

## 3. Write the proposal: `$D/_map/module-proposal.yaml`
Strict YAML subset (`references/modules-schema.md`). Example:
```yaml
backend: Ashoka-World-Backend
modules:
  - id: auth
    name: "Authentication"
    critical: false
    repos:
      - repo: Ashoka-World-Backend
        controllers:
          - AuthController
        extra_routes:
          - "POST turyaa/otp/send-otp"
        exclude_routes: []
      - repo: Nadi-Tarangini-Frontend
        controllers:
          - LoginController
        paths:
          - resources/views/auth/
      - repo: Nadi-Tarangini-App
        paths:
          - lib/common_files/Login/
```
Rules
- ids: kebab-case, stable (requirement IDs derive from them). Names: plain English.
- A controller's routes all join its module; split a shared controller with
  `exclude_routes` / `extra_routes` ("METHOD uri" exactly as in routes.json).
- `critical: true` for nadi-flow, payments and ENACH modules.
- Receptionist and the research dashboard are their own modules (confirmed not in
  use; see not-in-use.md).
- Prefer modules a QA tester or PO would recognise (auth, patients, appointments,
  nadi-flow, reports, payments, subscriptions, chatbot, notifications, admin...).
- Unassigned is allowed but must be explained (e.g. test/debug routes).

## 4. Preview until clean
`bash $S/build-modules.sh --root $R` prints the table, coverage, conflicts and
errors. Fix the proposal until there are **0 errors and 0 conflicts**, and keep
unassigned routes to the ones you can explain.

## 5. Ask for approval (mandatory)
Show the user: the preview table (id, name, repos/paths, route counts, critical),
the coverage line, and the unassigned routes grouped by URI prefix with your
reason. Ask: "Approve this module list?" **Do not write modules.yaml before a yes.**

## 6. After approval
1. `bash $S/build-modules.sh --root $R --write` writes `$D/modules.yaml`
   (owner/doc_status/in_use of existing modules are kept).
2. `bash $S/seed-docs.sh --root $R` creates environments.md, external-systems.md and
   not-in-use.md if missing (never overwrites).
3. If `$D/glossary.md` is missing, write it: domain terms found in code (model/table
   names, route segments, Dart folders: e.g. Prakruti, Prahar, Turyaa, Nadi,
   Swasthya), each as `| Term | Where seen (file) | Meaning |` with Meaning
   "TO CONFIRM". Never guess a meaning as fact. Status line: Draft, date.
4. Report: `X of Y backend routes assigned, Z unassigned`, files written, and the
   next step (`/atreya:link-apis`).
