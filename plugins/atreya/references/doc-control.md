# Document control

## Stamp (every BRD/PRD/staging-delta/impact doc)
Each doc starts with front matter in the strict YAML subset
(`scripts/yaml2json.sh --front-matter` reads it; `/atreya:sync` compares it):

```
---
module: auth
doc: PRD                     # BRD | PRD | staging-delta | impact
status: Draft                # Draft | Reviewed | Approved
date: 2026-10-26
reviewer: TBD
commits:                     # full HEAD hash of each repo the doc was built from
  Ashoka-World-Backend: <hash>
  Nadi-Tarangini-Frontend: <hash>
  Nadi-Tarangini-App: <hash>
---
```
Only a human moves a doc to Reviewed or Approved. Claude writes Draft.

Impact docs: `module` may list several ids (`"auth,patients"`, the directly
changed modules), `commits` covers all their repos, and `ticket:` names the Zoho
Sprints item or `adhoc-<slug>` (`doc-stamp.sh "<ids>" impact <ticket>`).

`/atreya:sync` uses the stamp: a doc is stale when `git log <stamp>..HEAD` shows
commits on its module's files (a diagram: on the files it cites).

Diagrams (`.drawio`) carry the same stamp: module, date and commits, as a visible
footer text and in the file's metadata (see the diagram skill).

## Evidence classes (impact analyses)
Every statement in an impact analysis carries one class
(`references/impact-facts-schema.md`): **Verified** (`Repo:path:line` at the
stamped commit, or the Zoho item's own text), **Inferred** (follows from cited
facts or a rule), **Assumption** (listed under assumptions, linked to a question),
**Unknown** (cannot be known statically; says why), **Not affected** (checked;
says what). Script facts and Claude's analysis are kept apart in
`impact-facts.json`; the facts carry a hash and are never edited by hand.
impact.md and impact-report.html are rendered as Draft; a human moves impact.md
to Reviewed or Approved.

## Never invent
- Every statement must be provable from code (cite `repo:path:line`), from the
  Zoho Sprints item, or from a human-owned doc (`environments.md`, glossary…).
- Anything else goes into **Needs confirmation** (BRD §12, PRD §13 Open questions),
  phrased as a question for a named role (owner/PO/dev), never as a fact.
- Values that look like keys, tokens or passwords are never copied. Write
  "[REDACTED]" and the file:line instead.

## IDs
- BRD business requirements: `BR-01`, `BR-02`, …
- PRD functional requirements: `<MODULE>-R01`, `<MODULE>-R02`, … where `<MODULE>`
  is the module id in upper case with `-` kept (`auth` → `AUTH-R01`,
  `nadi-flow` → `NADI-FLOW-R01`). Each has acceptance criteria and source refs.
  IDs are never reused or renumbered; removed requirements are marked "Removed".
  Phase-3 test cases link to these IDs.

## Critical modules (nadi-flow, payments, enach; `critical: true`)
1. Run the doc-checker agent twice: once on the draft, once after fixes.
2. List every "Needs confirmation" item to the user and wait for a decision on each.
