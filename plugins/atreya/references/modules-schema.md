# modules.yaml schema

`atreya-docs/modules.yaml` is the single source of truth for modules. It is
read with `scripts/yaml2json.sh`, which accepts only this strict YAML subset and
fails with the line number on anything else.

## Format rules
- 2-space indentation, spaces only. Lists are indented under their key.
- Values: plain, `"double quoted"`, `'single quoted'`, `[]` for an empty list.
  Quote any value that contains `: ` (e.g. `"POST api/login"` is fine unquoted,
  `"Note: x"` must be quoted).
- `true`/`false` are booleans, `null`/`~` null; everything else is a string
  (commit hashes stay strings).
- Comments: full lines, or ` # ...` after a value.
- Not allowed: tabs, `[a, b]` / `{a: b}` with content, anchors `&`/`*`, tags `!`,
  multi-line `|` / `>` values, duplicate keys.

## Fields
Written by `scripts/build-modules.sh --write` (every string double-quoted).
**Definition** fields (decide the module; edit these by hand if needed): `id`,
`name`, `product`, `critical`, and per repo `controllers`, `paths`,
`extra_routes`, `exclude_routes`. **Human-owned** fields (kept on every rewrite):
`owner`, `doc_status`, `in_use`. Everything else is **derived** and recomputed.
```yaml
version: "1"
generated: "2026-10-26"               # date of the last write
backend: "Ashoka-World-Backend"       # the API repo whose routes must all be covered
commits:                              # repo HEADs the map was built from
  Ashoka-World-Backend: "<full hash>"
modules:
  - id: "auth"                        # kebab-case, unique. Requirement IDs: AUTH-R01…
    name: "Authentication & sign-up"
    product: "nt"                     # nt | ashoka-admin | nadi-pariksha | turyaa
    owner: "TBD"
    doc_status: "none"                # none | draft | reviewed | approved
    critical: false                   # true: extra doc-checker pass + review of every
                                      # "Needs confirmation" (nadi-flow, payments, enach)
    repos:
      - repo: "Ashoka-World-Backend"
        controllers:                  # all their routes join the module
          - "AuthController"
        paths: []                     # extra files/folders (App modules use these)
        extra_routes: []              # single routes from other controllers ("METHOD uri")
        exclude_routes:               # routes of the listed controllers that belong elsewhere
          - "GET getCurrencyTypes"
        files:                        # derived: controller files + paths
          - "app/Http/Controllers/AuthController.php"
    routes:                           # derived: backend routes, exactly as in routes.json
      - "POST login"
    web_routes:                       # derived: routes of other Laravel repos (pages, forms)
      - repo: "Nadi-Tarangini-Frontend"
        routes:
          - "GET login"
    screens:                          # derived: views rendered by the controllers / files under paths
      - repo: "Nadi-Tarangini-App"
        path: "lib/common_files/Login/view/login_screen.dart"
    models: []                        # derived from the controller methods behind the routes
    tables: []
    external_systems: []              # derived from _map/*/externals.json
    in_use:                           # yes | no | partial | TBD (human-confirmed)
      dev: "TBD"
      staging: "TBD"
      production: "TBD"
unassigned_routes:                    # backend routes no module claims (explained in not-in-use.md)
  - "GET getPhpInfo"
```

Coverage rule: every backend route appears in exactly one module's `routes`
or in `unassigned_routes`. `scripts/coverage.sh` checks it and prints counts.
