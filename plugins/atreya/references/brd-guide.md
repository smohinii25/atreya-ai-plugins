# BRD guide

Audience: **non-technical** readers (management, sales, support, clinic staff).
Input: the same fact pack as the PRD (`_map/_modules/<id>/facts.md`), the PRD if
it exists, `environments.md`, `not-in-use.md`, glossary, optionally a Zoho Sprints
item. Output: `atreya-docs/nt/<id>/BRD.md` in the exact 13 headings of
`references/brd-template.md`, with the stamp from `doc-stamp.sh`.

## Writing rules
- Plain language. No routes, class names, table names or code in the body text;
  put the evidence only in a **Source** column (`Repo:path:line` or PRD ID).
- Same "cite or ask" rule as the PRD: business facts without a source go to
  §12 Needs confirmation. Objectives and success measures are almost never in
  code: write them as questions for the product owner ("TO CONFIRM").
- Translate rules from code into business rules: a validation
  "user_name required, password required" becomes "A user must enter both a
  username and a password to log in."
- Features listed in `not-in-use.md` or as "no screen calls" are out of scope
  or questions, never presented as live.

## Business requirements (§7)
Table, one row per requirement, IDs `BR-01…` defined once:
```
| ID | Requirement | Source |
|---|---|---|
| BR-01 | A doctor can sign in with a username and password. | AUTH-R01; `Ashoka-World-Backend:app/Http/Controllers/AuthController.php:42` |
```
Keep existing BR IDs when the BRD is updated (same rule as PRD IDs).

## Sections
1. **Purpose & overview**: what this part of the product lets people do.
2. **Business objectives**: TO CONFIRM unless a ticket states them.
3. **Stakeholders & user roles**: roles that use it (doctor, patient, admin…), cited.
4. **Scope**: In scope (capabilities in code) / Out of scope (other modules, not-in-use items).
5. **Current business process (as-is)**: the journey in plain steps.
6. **Business rules**: from validations and error messages, in plain words, cited.
7. **Business requirements**: the BR table.
8. **Availability by environment**: from `environments.md` (TO FILL stays TO FILL).
9. **Dependencies & external systems**: plain names (e.g. "SMS/OTP provider"), cited.
10. **Assumptions & constraints**: only provable ones; the rest to §12.
11. **Success measures (TO CONFIRM)**: questions for the product owner.
12. **Needs confirmation**: numbered questions, each for a role.
13. **Document control**: status, date, reviewer, commits.
