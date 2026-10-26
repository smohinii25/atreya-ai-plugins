#!/bin/bash
# build-modules.sh [--root R] [--from FILE] [--write]
#
# Expands a module DEFINITION (which controllers / paths belong to which module)
# into the full modules.yaml, deterministically, from the _map/ data:
#   routes (backend), web_routes (other Laravel repos), screens, models, tables,
#   external systems, unassigned_routes, and route coverage.
# FILE (strict YAML, default atreya-docs/_map/module-proposal.yaml, or an
# existing modules.yaml) — per module:
#   id, name, critical, repos: [{repo, controllers[], paths[], extra_routes[], exclude_routes[]}]
# Without --write: prints the preview (id, name, repos/paths, route counts,
# conflicts, coverage) and writes nothing. With --write: writes
# atreya-docs/modules.yaml, keeping owner / doc_status / in_use of existing modules.
# Exit 1 if a route is claimed by two modules or a name is unknown.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
FROM="$DOCS/_map/module-proposal.yaml"; WRITE=0
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do case "$1" in --from) FROM="$2"; shift 2 ;; --write) WRITE=1; shift ;; *) die "unknown argument $1" ;; esac; done
DEF=$(bash "$ATREYA_SCRIPTS/yaml2json.sh" "$FROM") || exit 1
BACKEND=$(printf '%s' "$DEF" | "$JQ" -r '.backend // empty'); [ -n "$BACKEND" ] || die "$FROM: missing 'backend: <repo>'"
OLD='{"modules":[]}'; [ -f "$DOCS/modules.yaml" ] && { OLD=$(bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml") || exit 1; }

# All mapped data, keyed by repo. Passed through temp files: the JSON is too
# large for command-line arguments.
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atreya-build.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT
f_or_null() { [ -f "$1" ] && echo "$1" || echo /dev/null; }
for d in "$DOCS"/_map/*/; do
  r=${d%/}; r=${r##*/}
  "$JQ" -n --arg r "$r" \
    --slurpfile routes "$(f_or_null "$d/routes.json")" --slurpfile ctl "$(f_or_null "$d/controllers.json")" \
    --slurpfile scr "$(f_or_null "$d/screens.json")" --slurpfile ext "$(f_or_null "$d/externals.json")" \
    '{($r): {routes: $routes[0], controllers: $ctl[0], screens: $scr[0], externals: $ext[0]}}'
done | "$JQ" -s 'add // {}' > "$TMPD/data.json" || die "cannot read _map data"
printf '%s' "$DEF" > "$TMPD/def.json"; printf '%s' "$OLD" > "$TMPD/old.json"

RES=$("$JQ" -n --slurpfile def0 "$TMPD/def.json" --slurpfile D0 "$TMPD/data.json" --slurpfile old0 "$TMPD/old.json" --arg backend "$BACKEND" '
  $def0[0] as $def | $D0[0] as $D | $old0[0] as $old |
  def short: split("\\") | last;
  def under($ps): . as $f | any($ps[]; . as $p | $f == $p or ($f | startswith($p | sub("/?$"; "/"))));
  # PHP class names are case-insensitive (routes may say LoginController for class loginController)
  def ctlmatch($cs): . as $fq | $fq != null and any($cs[] | ascii_downcase; . == ($fq | ascii_downcase) or . == ($fq | short | ascii_downcase));
  ($old.modules | map({key: .id, value: .}) | from_entries) as $prev |
  [ $def.modules[] as $m | {
      m: $m,
      parts: [ ($m.repos // [])[] as $e | ($D[$e.repo] // null) as $d |
        (($e.controllers // [])) as $cs | (($e.paths // [])) as $ps |
        (if $d == null then {error: "repo \($e.repo) is not mapped (run /atreya:map \($e.repo))"} else
        # known = parsed controllers + controllers named by routes (guarded files are never parsed)
        ([$cs[] | . as $c | select(((([$d.controllers.controllers[]?.fqcn] + [($d.routes.routes // [])[].controller | select(. != null)]) | unique) | any(ascii_downcase == ($c | ascii_downcase) or (short | ascii_downcase) == ($c | ascii_downcase))) | not)]) as $unknownc |
        ([($d.routes.routes // [])[] | select((.shadowed | not) and (.controller | ctlmatch($cs))) | .key]) as $byc |
        ([($d.routes.routes // [])[] | .key] | unique) as $allkeys |
        ([($e.extra_routes // [])[], ($e.exclude_routes // [])[] | select(. as $k | $allkeys | index($k) | not)]) as $unknownr |
        ((($byc + ($e.extra_routes // [])) | unique) - ($e.exclude_routes // [])) as $keys |
        ([($d.controllers.controllers // [])[] | select(.fqcn | ctlmatch($cs)) | .file]) as $cfiles |
        ([($d.routes.routes // [])[] | select(.key as $k | $keys | index($k)) | {c: (.controller // "" | ascii_downcase), a: (.action // "" | ascii_downcase)}] | unique) as $acts |
        ([($d.controllers.controllers // [])[] as $k | $k.methods[] | select(({c: ($k.fqcn | ascii_downcase), a: (.name | ascii_downcase)}) as $x | $acts | index($x)) ]) as $meths |
        (($cfiles + $ps) | unique) as $paths |
        {repo: $e.repo, controllers: $cs, paths: $ps, extra_routes: ($e.extra_routes // []), exclude_routes: ($e.exclude_routes // []),
         files: $paths, keys: $keys,
         screens: [($d.screens.screens // [])[] | select((.partial // false) | not) |
                   select(((.rendered_by // []) | any(.controller | ctlmatch($cs))) or (.file != null and (.file | under($ps)))) | {repo: $e.repo, path: .file, id: .id}],
         models: [$meths[].models[]] | unique, tables: [$meths[].tables[]] | unique,
         externals: [($d.externals.systems // [])[] | select(any(.files[].file; under($paths))) | .system],
         errors: ([$unknownc[] | "unknown controller \(.) in \($e.repo)"] + [$unknownr[] | "unknown route \(.) in \($e.repo)"])}
        end) ]
    } ] as $mods |
  ($D[$backend].routes.routes // [] | map(select(.shadowed | not) | .key) | unique) as $broutes |
  ([$mods[] | .m.id as $id | .parts[] | select(.repo == $backend) | .keys[] | {key: ., id: $id}] | group_by(.key)
    | map(select(length > 1) | {route: .[0].key, modules: map(.id)})) as $conflicts |
  ([$mods[] | .parts[] | select(.repo == $backend) | .keys[]] | unique) as $assigned |
  ([$mods[] | .parts[] | (.error // empty), (.errors // [])[]] + [$mods[] | .m.id | select(test("^[a-z0-9]+(-[a-z0-9]+)*$") | not) | "bad module id \(.) (kebab-case)"]
    + ([$mods[].m.id] | group_by(.) | map(select(length > 1) | "duplicate module id \(.[0])"))) as $errors |
  {
    errors: $errors, conflicts: $conflicts,
    coverage: {backend: $backend, routes: ($broutes | length), assigned: ([$assigned[] | select(. as $k | $broutes | index($k))] | length),
               unassigned: (($broutes - $assigned) | length)},
    modules: [$mods[] | .m as $m | ($prev[$m.id] // {}) as $p | {
      id: $m.id, name: $m.name, product: ($m.product // $p.product // "nt"),
      owner: ($p.owner // "TBD"), doc_status: ($p.doc_status // "none"), critical: ($m.critical // false),
      repos: [.parts[] | select(.error == null) | {repo, controllers, paths, extra_routes, exclude_routes, files}],
      routes: ([.parts[] | select(.repo == $backend) | .keys[]] | unique),
      web_routes: [.parts[] | select(.repo != $backend and (.keys | length) > 0) | {repo, routes: .keys}],
      screens: ([.parts[] | .screens[]?] | unique_by(.repo, .path) | map({repo, path})),
      models: ([.parts[].models[]?] | unique), tables: ([.parts[].tables[]?] | unique),
      external_systems: ([.parts[].externals[]?] | unique),
      in_use: ($p.in_use // {dev: "TBD", staging: "TBD", production: "TBD"})
    }],
    unassigned_routes: ($broutes - $assigned)
  }') || die "could not expand modules"

# ---- preview
printf '%s' "$RES" | "$JQ" -r '
  "| id | name | repos / paths | backend routes | web routes | screens | models | critical |",
  "|---|---|---|---|---|---|---|---|",
  (.modules[] | "| \(.id) | \(.name) | \(.repos | map("\(.repo): \((.controllers | length)) ctl, \((.paths | length)) paths") | join("<br>")) | \(.routes | length) | \(.web_routes | map(.routes | length) | add // 0) | \(.screens | length) | \(.models | length) | \(.critical) |"),
  "",
  "Coverage (\(.coverage.backend)): \(.coverage.assigned) of \(.coverage.routes) routes assigned, \(.coverage.unassigned) unassigned.",
  (if (.unassigned_routes | length) > 0 then "Unassigned (first 60):", (.unassigned_routes[0:60][] | "  \(.)") else empty end),
  (if (.conflicts | length) > 0 then "CONFLICTS (route claimed by more than one module):", (.conflicts[] | "  \(.route): \(.modules | join(", "))") else "Conflicts: none." end),
  (if (.errors | length) > 0 then "ERRORS:", (.errors[] | "  \(.)") else empty end)'
OKAY=$(printf '%s' "$RES" | "$JQ" -r 'if (.errors | length) == 0 and (.conflicts | length) == 0 then "yes" else "no" end')
[ "$OKAY" = yes ] || { echo "not written: fix the errors/conflicts above in $FROM"; exit 1; }
[ $WRITE = 1 ] || { echo "preview only (nothing written). Re-run with --write after approval."; exit 0; }

# ---- write modules.yaml in the strict subset (all strings double-quoted)
YAML=$(printf '%s' "$RES" | "$JQ" -r --arg backend "$BACKEND" --arg date "$(today)" --argjson commits "$("$JQ" -c 'to_entries | map({key, value: (.value.routes.commit // .value.screens.commit)}) | from_entries' "$TMPD/data.json")" '
  def q: tostring | gsub("\r"; "") | tojson;
  def list($ind): if length == 0 then " []" else "\n" + (map($ind + "- " + q) | join("\n")) end;
  "# atreya modules (single source of truth). Written by /atreya:map --merge.",
  "# Edit by hand only in this strict format: references/modules-schema.md",
  "version: \(1 | q)", "generated: \($date | q)", "backend: \($backend | q)",
  "commits:", ($commits | to_entries[] | "  \(.key): \(.value | q)"),
  "modules:",
  (.modules[] |
    "  - id: \(.id | q)", "    name: \(.name | q)", "    product: \(.product | q)",
    "    owner: \(.owner | q)", "    doc_status: \(.doc_status | q)", "    critical: \(.critical)",
    "    repos:" + (if (.repos | length) == 0 then " []" else "" end),
    (.repos[] | "      - repo: \(.repo | q)",
      "        controllers:" + (.controllers | list("          ")),
      "        paths:" + (.paths | list("          ")),
      "        extra_routes:" + (.extra_routes | list("          ")),
      "        exclude_routes:" + (.exclude_routes | list("          ")),
      "        files:" + (.files | list("          "))),
    "    routes:" + (.routes | list("      ")),
    "    web_routes:" + (if (.web_routes | length) == 0 then " []" else "" end),
    (.web_routes[] | "      - repo: \(.repo | q)", "        routes:" + (.routes | list("          "))),
    "    screens:" + (if (.screens | length) == 0 then " []" else "" end),
    (.screens[] | "      - repo: \(.repo | q)", "        path: \(.path | q)"),
    "    models:" + (.models | list("      ")),
    "    tables:" + (.tables | list("      ")),
    "    external_systems:" + (.external_systems | list("      ")),
    "    in_use:", "      dev: \(.in_use.dev | q)", "      staging: \(.in_use.staging | q)", "      production: \(.in_use.production | q)"),
  "unassigned_routes:" + (.unassigned_routes | list("  "))')
TMPY="$TMPD/modules.yaml"
printf '%s\n' "$YAML" > "$TMPY"
bash "$ATREYA_SCRIPTS/yaml2json.sh" "$TMPY" >/dev/null || die "generated YAML failed validation (bug)"
[ -f "$DOCS/modules.yaml" ] && cp "$DOCS/modules.yaml" "$DOCS/_map/modules.yaml.prev"
mv "$TMPY" "$DOCS/modules.yaml"
echo "wrote $DOCS/modules.yaml"
