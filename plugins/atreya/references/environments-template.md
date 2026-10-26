# Environments

Status: **TO FILL**. Filled by a human. Never filled from `.env` or any secret file.

`Ref` is what that environment runs: a branch (`origin/master`), a tag, or a
commit. `/atreya:prd` copies these rows into each PRD's Environment matrix;
staging-delta compares the staging and production refs and skips any repo whose
refs still say TO FILL ("waiting for environments.md").

## Ashoka-World-Backend

| Env | Ref | Host | Feature flags | Integration mode |
|---|---|---|---|---|
| dev | TO FILL | TO FILL | TO FILL | TO FILL |
| staging | TO FILL | TO FILL | TO FILL | TO FILL |
| production | TO FILL | TO FILL | TO FILL | TO FILL |

## Nadi-Tarangini-Frontend

| Env | Ref | Host | Feature flags | Integration mode |
|---|---|---|---|---|
| dev | TO FILL | TO FILL | TO FILL | TO FILL |
| staging | TO FILL | TO FILL | TO FILL | TO FILL |
| production | TO FILL | TO FILL | TO FILL | TO FILL |

## Nadi-Tarangini-App

| Env | Ref | Build flavor | Host | Feature flags | Integration mode |
|---|---|---|---|---|---|
| dev | TO FILL | TO FILL | TO FILL | TO FILL | TO FILL |
| staging | TO FILL | TO FILL | TO FILL | TO FILL | TO FILL |
| production | TO FILL | TO FILL | TO FILL | TO FILL | TO FILL |

## Notes from git (not confirmed)
- Backend and Frontend: only `origin/master` is active; `origin/dev` and
  `origin/main` stopped in early 2024 and are contained in master.
- App: only `origin/production` is active (default branch). Staging vs production
  is a build flavor (`main_staging.dart` / `main_prod.dart`), not a branch.
- Integration mode examples: Razorpay test/live, ENACH sandbox/live, Interakt
  sandbox/live.
