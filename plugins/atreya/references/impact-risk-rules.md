# Impact risk rules

`scripts/lib/impact-risk.jq` applies these rules to the script facts and writes
one record per hit: `{id: RS-nn, rule, level, reason, consequence, evidence,
confidence, modules}`. Claude may add records (`RA-nn`) with the FAIL rules or
any rule below, or raise a script record; never lower one (ask in open questions
instead). Every level in a report can be traced to one of these lines.

Name patterns (money tables, money external systems, money modules, security
words) live in `config/impact-signals.yaml` (human-owned). A hit found only by a
name pattern is evidence class **Inferred**.

| Rule | Level | Fires when | Consequence written in the record |
|---|---|---|---|
| MONEY-01 | Critical | A money external system (Razorpay, ENACH) is used inside the changed code | wrong amount or account charged, refunded or mandated |
| MONEY-02 | Critical | A changed table (`--table`, seeded model or migration) is a money table, or changed code writes one | money records lost, duplicated or misstated |
| MONEY-03 | High | Changed code reads a money table, or a module listed under `money.modules` is indirectly affected | amounts or statuses shown or used wrongly |
| CRIT-01 | High | A `critical: true` module is directly changed | a core flow breaks for every user of the module |
| CRIT-02 | Medium | A critical module is indirectly affected | a core flow changes without its code changing |
| SEC-01 | High | A changed route URI, controller@method, middleware or changed method name contains a security word | lock-out, or access granted or kept wrongly |
| DATA-01 | High | A changed table is used by 3 or more modules | every reader shows or stores wrong data |
| DATA-02 | Medium | A changed table is shared by 2 modules | the other module shows or stores wrong data |
| DATA-03 | Medium (High if a table is a money table) | One changed method writes 2 or more tables without `DB::transaction` / `beginTransaction` | a failure between the writes leaves the tables inconsistent |
| DATA-04 | Low | Changed code writes a table other modules read (structure unchanged) | readers see different data if the values written change |
| DEP-01 | High | 4 or more modules directly changed | many flows change at once |
| DEP-02 | Medium | 2–3 modules directly changed | changes must be released and tested together |
| DEP-03 | High / Medium | 6 or more modules affected in total / 3 or more indirect | wide regression surface |
| CALL-01 | Medium | A changed backend route is called by both web and app | both clients must be tested; the app may lag |
| EXT-01 | Medium | Changed code uses a (non-money) external system | third-party behaviour, limits or outages affect the flow |
| FAIL-01 | Critical | (Claude) a workflow step's failure blocks or corrupts money movement | from the workflow step |
| FAIL-02 | High | (Claude) a step's failure blocks login or a core business workflow | from the workflow step |
| FAIL-03 | Medium | (Claude) a step's failure degrades the experience, with a workaround | from the workflow step |
| FAIL-04 | Low | (Claude) a step's failure is cosmetic | from the workflow step |

The v1 levels (High / Medium / Low / TBD from references/impact-guide.md) are still
computed into `risk.level` and shown as "v1 rule level" for continuity.

## Overall level and confidence
- **Overall** = the highest level of all records (script and analysis). No
  module matched the seeds → **TBD**. No record → **Low**.
- **Confidence** of a record: Verified → High, Inferred → Medium, Assumption /
  Unknown → Low.
- **Overall confidence**: Low if any conflicting evidence exists or a deciding
  record (one at the overall level) is Low; else Medium if a deciding record is
  Medium or there are unknown links in the changed area (not counting the standing
  "state shared outside routes and tables" item); else High. When the analysis
  raised the level, its records decide.
