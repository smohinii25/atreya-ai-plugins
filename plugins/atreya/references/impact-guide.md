# Impact guide

Input: one change, as a Zoho Sprints item (read with **Get** tools only) or free
text. Output: `atreya-docs/dev/<ticket>/impact.md` (free text:
`dev/adhoc-<slug>/impact.md`) in the 12 headings of
`references/impact-template.md`, plus `impact-facts.md|json` from
`scripts/impact-facts.sh`. An impact doc describes one change at one moment;
`/atreya:sync` does not track it.

## How it is built
1. **Seeds (Claude).** Decide what the change touches, from the ticket and the
   code. Each seed needs a reason you can cite:
   - `--file Repo:path:line` a line inside the method that changes (the script
     widens it to the whole method and the routes that call it); `--file Repo:path`
     only when the whole file changes;
   - `--route "METHOD uri"` a backend route whose behaviour changes;
   - `--table name` only when a table's **structure or meaning** changes (new or
     changed column, new allowed value) — not because the code reads it;
   - `--screen Repo:ScreenId`, `--module id` (a module changed as a whole).
   Start narrow: seed the code that must change, not everything nearby. Do not
   seed the callers: the script finds them.
2. **Expansion (script).** `impact-facts.sh` derives everything else from
   modules.yaml and `_map/` and suggests the risk level and QA scope (rules
   below). It refuses unknown seeds and secret files.
   The script sees code, routes, tables and screens. It does **not** see state
   shared another way: cache keys, session keys, queues, files on S3. Check those
   by hand in the changed methods (e.g. a cache key built from the phone number
   that another module also reads) and list what you find as Related, with citations.
3. **Write (Claude).** impact.md explains the facts for a developer and a tester.
   Every statement cites `Repo:path:line`, `Zoho Sprints <id>`, or the facts file;
   anything else goes to §11. Never invent a fix: describe what is affected, not
   how to implement it, unless the ticket says so.

## Sections
1. **Change**: the ticket title and text (quoted, short) or the free text; the
   source; what is asked, in one or two sentences.
2. **Summary**: risk level, number of modules, the main reason.
3. **Affected modules**: Direct (code that changes) and Related (share a changed
   table, or call a changed route), each with the "why" from the facts.
4. **Code**: seeds and changed spans; backend routes changed (controller,
   middleware, tables) and every client caller; web routes; API calls made from
   changed client code.
5. **Screens**: web pages and app screens that show or call the changed code.
6. **Data**: changed tables (with the modules that use them) and tables only
   read (context).
7. **External systems** used inside the changed code.
8. **Docs & diagrams to update**: from the facts' "Docs and diagrams citing the
   changed code" — doc, requirement IDs / BR rows / sections, diagram names. A
   hit marked "(route line only)" means the doc lists the route; update it only
   if the route itself changes (URI, method, middleware). Also search the
   modules' open questions (PRD §13, BRD §12) for the change's key words: the
   change may answer one of them. Add docs the change should create (e.g. a new
   requirement) as a suggestion.
9. **Risk**: level and every signal behind it (below). Claude may argue for a
   different level, but must show the script's level and why it differs. If the
   level depends on an open decision, write it as conditional, e.g.
   "Medium (High if the account is blocked: §11 Q2)", and link the §11 question.
10. **QA to rerun**: sanity and regression modules, web pages to check, what QA
    cannot cover (app, backend only), and limits from `references/qa-scope-rules.md`
    (e.g. OTP steps are skipped: no real OTP codes).
11. **Needs confirmation**: questions for PO / dev / QA, each for a named role.
12. **Document control**: who reviews; status stays Draft until a human changes it.

## Risk rules (suggested level; impact-facts.sh computes the signals)
- **High** if any of: a critical module is directly changed (nadi-flow, payments,
  enach); Razorpay or ENACH code is inside the changed code; a changed table is
  used by 3 or more modules; 4 or more modules are directly changed.
- **Medium** if any of: 2–3 modules directly changed; a changed backend route is
  called by both web and app; a changed table is shared by 2 modules; the changed
  code uses any external system.
- **Low** otherwise. **TBD** when the seeds match no module (check the seeds).

## QA rules (web staging only, references/qa-scope-rules.md)
- **Sanity**: directly changed modules that have web pages, with the pages.
- **Regression**: sanity + related modules that have web pages.
- **Not covered by QA**: modules with no web pages (app or backend only) and the
  app screens affected — list them so the developer tests them.
