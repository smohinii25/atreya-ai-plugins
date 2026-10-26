# PRD guide

Input: `atreya-docs/_map/_modules/<id>/facts.md` (fact pack), the module's
`staging-delta.md`, `environments.md`, optionally one Zoho Sprints item, and
targeted reads of cited code. Output: `atreya-docs/nt/<id>/PRD.md` in the exact
15 headings of `references/prd-template.md`, with the stamp from `doc-stamp.sh`.

## Rules
- **Cite or ask.** Every factual sentence ends with a citation: `Repo:path:line`
  (or `Repo:path`), `Zoho Sprints <item>`, or a human doc (`environments.md`,
  `glossary.md`, `references/qa-scope-rules.md`). Anything without one goes to
  §13 Open questions, phrased as a question for a role (PO, dev, QA).
- Describe behaviour, not intent. "The login API returns 400 'Username is
  required' when user_name is missing" is provable; "this keeps accounts safe" is not.
- Glossary terms marked TO CONFIRM may be used as names, never explained.
- Never copy secrets or long code. Code identifiers only in tables, sources and §6/§7.
- Routes listed in the fact pack under "no screen calls" are stated as such
  (and asked about in §13), not described as live features.

## Requirement format (§4)
```
### AUTH-R01: Log in with username and password
Plain statement of what the system does, with citations.
**Acceptance criteria**
- Given … when … then … (from validation rules, error messages, responses)
**Source**: `Ashoka-World-Backend:app/Http/Controllers/AuthController.php:42`, …
**Screens**: LoginScreen (App), auth.login (Web) · **API**: POST v2/loginValidation
```
- IDs: `<MODULE>-R01…` (module id upper-cased). One requirement per user-visible
  capability (group routes that serve one capability).
- **If PRD.md already exists**: keep every existing ID and its meaning; add new
  ones after the highest number; mark dropped ones `Removed (reason)`; never renumber.

## Sections
1. **Overview**: what the module covers, in 3-5 sentences, from routes/screens.
2. **Users, roles & permissions**: who reaches each part, from middleware
   (e.g. `auth.token`, `client.authentication`, none = public) and role data. Cite.
3. **User journeys**: ordered steps per journey, from screens, navigation
   ("goes to") and API calls. Web and mobile separately where they differ.
4. **Functional requirements**: the requirement blocks above.
5. **Screens**: table `Screen | Platform | File | Route / path | Purpose (provable)`.
6. **APIs**: table `Method | Endpoint | Controller | Auth (middleware) | Called by`.
7. **Data model**: table per table: key fields from migrations; "columns not in
   migrations" → §13.
8. **Validations & error handling**: table `API | Field / case | Rule or message |
   HTTP | Source`, from the fact pack.
9. **Non-functional**: security (auth middleware, OTP), languages: required list
   (source `references/qa-scope-rules.md`) vs language files found in code;
   performance only if code shows it (timeouts, limits).
10. **Environment matrix**: copy the module's repos' rows from `environments.md`
    verbatim; "TO FILL" stays "TO FILL".
11. **Staging delta**: link `staging-delta.md`; state its status (e.g. waiting for
    environments.md). Do not summarise a delta that was not computed.
12. **External integrations**: from the fact pack's external systems, with where.
13. **Open questions**: every Needs-confirmation item, numbered, each for a role.
14. **Diagrams**: list diagrams in `nt/<id>/diagrams/`, or "None yet: run
    /atreya:diagram <id>".
15. **Document control**: status, date, reviewer, commits (same as the stamp).
