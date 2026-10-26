#!/bin/bash
# module-facts.sh [--root R] MODULE_ID
#
# Deterministic fact pack for one module, the ONLY base for PRD/BRD drafting:
#   atreya-docs/_map/_modules/<id>/facts.json  and  facts.md
# Contents: module record, repo commits, backend routes (controller@method,
# middleware, file:line) with their callers, validation rules and error messages
# found in the controller methods (and FormRequest rules()), web routes, screens
# and navigation, API links, tables with known columns, external systems
# (file:line), routes no screen calls, the environment matrix from
# environments.md (verbatim, "TO FILL" kept), and language files.
# Values pass the redaction filter. Guarded files are never opened.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
ID="${ARGS[0]:-}"; [ -n "$ID" ] || die "usage: module-facts.sh --root R MODULE_ID"
[ -f "$DOCS/modules.yaml" ] || die "no modules.yaml (run /atreya:map --merge)"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atreya-facts.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT
bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml" > "$TMPD/modules.json" || exit 1
"$JQ" -e --arg id "$ID" '.modules | any(.id == $id)' "$TMPD/modules.json" >/dev/null || die "unknown module $ID"
BACKEND=$("$JQ" -r '.backend' "$TMPD/modules.json"); BD="$DOCS/_map/$BACKEND"
OUTD="$DOCS/_map/_modules/$ID"; mkdir -p "$OUTD" || die "cannot create $OUTD"
f_or_null() { [ -f "$1" ] && echo "$1" || echo /dev/null; }

# ---- validation rules + error messages inside the module's backend controller methods
"$JQ" -r --arg id "$ID" --slurpfile r "$BD/routes.json" --slurpfile c "$BD/controllers.json" '
  (.modules[] | select(.id == $id) | .routes) as $keys |
  [$r[0].routes[] | select(.shadowed | not) | select(.key as $k | $keys | index($k)) | select(.controller != null and .controller_status == "found")] as $rs |
  ([$c[0].controllers[] as $k | $k.methods[] | {k: (($k.fqcn | ascii_downcase) + "@" + (.name | ascii_downcase)), file: $k.file, from: .lines[0], to: .lines[1]}] | map({key: .k, value: .}) | from_entries) as $span |
  $rs[] | ($span[((.controller | ascii_downcase) + "@" + (.action // "" | ascii_downcase))] // empty) as $s |
  "\(.key)\t\($s.file)\t\($s.from)\t\($s.to)"' "$TMPD/modules.json" > "$TMPD/spans.tsv"
: > "$TMPD/rules.tsv"
while IFS='	' read -r key file from to; do
  [ -n "$file" ] || continue
  is_secret_name "$file" && continue
  awk -v key="$key" -v file="$file" -v from="$from" -v to="$to" '
    NR < from || NR > to { next }
    /^[ \t]*(\/\/|\*|#)/ { next }
    /Validator::make\(|->validate\(|\$rules[ \t]*=[ \t]*\[/ { inr = 1; d = 0 }
    inr {
      s = $0
      if (match(s, /["\047][A-Za-z_.*]+["\047][ \t]*=>[ \t]*["\047][^"\047]+["\047]/)) {
        f = substr(s, RSTART, RLENGTH); r = f; sub(/^["\047]/, "", f); sub(/["\047].*/, "", f); sub(/^[^=]*=>[ \t]*["\047]/, "", r); sub(/["\047]$/, "", r)
        if (r ~ /(required|nullable|sometimes|string|integer|numeric|email|min:|max:|in:|date|boolean|array|digits|regex|unique|exists|confirmed|size:|mimes)/) printf "V\t%s\t%s:%d\t%s\t%s\n", key, file, NR, f, r }
      t = s; o = gsub(/\[/, "[", t); cl = gsub(/\]/, "]", t); d += o - cl; if (d <= 0 && $0 ~ /\]/) inr = 0 }
    match($0, /["\047]message["\047][ \t]*=>[ \t]*["\047][^"\047]+["\047]/) {
      m = substr($0, RSTART, RLENGTH); sub(/^[^=]*=>[ \t]*["\047]/, "", m); sub(/["\047]$/, "", m); pend = m; pl = NR; code = "" }
    pend != "" && match($0, /\][ \t]*,[ \t]*[1-5][0-9][0-9][ \t]*\)/) { code = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", code) }
    pend != "" && (NR - pl >= 4 || code != "") { printf "M\t%s\t%s:%d\t%s\t%s\n", key, file, pl, code, pend; pend = "" }
    END { if (pend != "") printf "M\t%s\t%s:%d\t\t%s\n", key, file, pl, pend }' "$ROOT/repos/$BACKEND/$file" >> "$TMPD/rules.tsv"
done < "$TMPD/spans.tsv"
redact < "$TMPD/rules.tsv" > "$TMPD/rules.red.tsv"

# ---- environment matrix (verbatim rows from environments.md)
: > "$TMPD/env.tsv"
# rows "R<TAB>repo<TAB>cells..." and each repo's own header "H<TAB>repo<TAB>cells..."
[ -f "$DOCS/environments.md" ] && awk '
  /^## / { repo = substr($0, 4) }
  repo != "" && /^\|/ && $0 !~ /^\|[-| ]*\|$/ { line = $0; gsub(/^\| *| *\|$/, "", line); n = split(line, a, / *\| */)
    printf "%s\t%s", (a[1] == "Env" ? "H" : "R"), repo; for (i = 1; i <= n; i++) printf "\t%s", a[i]; printf "\n" }
' "$DOCS/environments.md" | redact > "$TMPD/env.tsv"
ENVHDR=""

# ---- language files (names only)
LANGS=$(for d in "$ROOT"/repos/*/; do r=${d%/}; r=${r##*/}; tracked_files "$d" 'resources/lang/*' 'lib/l10n/*' 'assets/translations/*' 'assets/lang/*' 2>/dev/null | sed "s#^#$r	#"; done)

# ---- assemble
CLIENT_LINKS=$(for d in "$DOCS"/_map/*/; do [ -f "$d/api-links.json" ] && printf '%s ' "$d/api-links.json"; done)
[ -n "$CLIENT_LINKS" ] && "$JQ" -s '[.[].links[]]' $CLIENT_LINKS > "$TMPD/links.json" || echo '[]' > "$TMPD/links.json"
for d in "$DOCS"/_map/*/; do r=${d%/}; r=${r##*/}; [ "$r" = _modules ] && continue
  "$JQ" -n --arg r "$r" --slurpfile routes "$(f_or_null "$d/routes.json")" --slurpfile scr "$(f_or_null "$d/screens.json")" \
    --slurpfile ext "$(f_or_null "$d/externals.json")" --slurpfile mod "$(f_or_null "$d/models.json")" \
    '{($r): {routes: $routes[0], screens: $scr[0], externals: $ext[0], models: $mod[0]}}'
done | "$JQ" -s 'add' > "$TMPD/data.json"
printf '%s\n' "$LANGS" > "$TMPD/langs.tsv"; printf '%s\n' "$ENVHDR" > "$TMPD/envhdr.tsv"

"$JQ" -n --arg id "$ID" --arg backend "$BACKEND" --arg date "$(today)" \
  --slurpfile M "$TMPD/modules.json" --slurpfile D "$TMPD/data.json" --slurpfile L "$TMPD/links.json" \
  --rawfile rules "$TMPD/rules.red.tsv" --rawfile env "$TMPD/env.tsv" --rawfile envhdr "$TMPD/envhdr.tsv" --rawfile langs "$TMPD/langs.tsv" '
  def rows($t): $t | split("\n") | map(select(length > 0) | split("\t"));
  def short: split("\\") | last;
  ($M[0].modules[] | select(.id == $id)) as $m | $D[0] as $D | $L[0] as $links |
  (rows($rules)) as $R |
  ([$m.repos[].repo] + [$m.screens[].repo] + [$m.web_routes[].repo] + [$backend] | unique) as $repos |
  ($repos | map({key: ., value: ($D[.].routes.commit // $D[.].screens.commit // null)}) | from_entries) as $commits |
  ([$links[] | select(.module == $id or .caller_module == $id)]) as $mylinks |
  # same rule as link-apis.sh: one definition (file:line) = one route (Route::match)
  ([$links[] | select(.status == "matched") | .route] | unique) as $hit |
  ([$D[$backend].routes.routes[] | {key, d: "\(.file):\(.line)"}]) as $defs |
  ([$defs[] | select(.key as $k | $hit | index($k)) | .d] | unique) as $hitDefs |
  ([$defs[] | select(.d as $d | $hitDefs | index($d)) | .key] + $hit | unique) as $called |
  ($envhdr | rtrimstr("\n") | split("\t")) as $eh |
  {
    module: ($m | {id, name, product, critical, owner, doc_status, in_use}),
    generated: $date, backend: $backend, commits: $commits,
    backend_routes: [$D[$backend].routes.routes[] | select(.shadowed | not) | select(.key as $k | $m.routes | index($k)) | . as $r |
      {key, method, uri, name, middleware,
       controller: (if .controller then "\(.controller | short)@\(.action // "")" else (.action // "closure") end),
       source: "\($backend):\(.file):\(.line)",
       controller_source: (if .controller_file then "\($backend):\(.controller_file)" else null end),
       controller_status,
       called_by: ([$links[] | select(.route == $r.key and .status == "matched") | {client, caller, pages}] | unique_by(.client, .caller)),
       validation: [$R[] | select(.[0] == "V" and .[1] == $r.key) | {field: .[3], rules: .[4], source: "\($backend):\(.[2])"}],
       errors: [$R[] | select(.[0] == "M" and .[1] == $r.key) | {http: (if .[3] == "" then null else .[3] end), message: .[4], source: "\($backend):\(.[2])"}]}],
    not_called: [$m.routes[] | select(. as $k | $called | index($k) | not)],
    web_routes: [$m.web_routes[] as $w | ($D[$w.repo].routes.routes // [])[] | select(.key as $k | $w.routes | index($k)) |
      {repo: $w.repo, key, name, middleware, controller: (if .controller then "\(.controller | short)@\(.action // "")" else (.action // "closure") end), source: "\($w.repo):\(.file):\(.line)"}],
    screens: [$m.screens[] as $s | (($D[$s.repo].screens.screens // [])[] | select(.file == $s.path)) as $x |
      {repo: $s.repo, id: $x.id, file: "\($s.repo):\($s.path)",
       routes: ($x.routes // []), rendered_by: ($x.rendered_by // [] | map("\(.controller | short)@\(.method)")),
       links_to: (($x.links_to // []) + ($x.navigates_to // []))}],
    api_calls: [$mylinks[] | {client, caller, pages, method, endpoint, status, route, controller, tables, source: "\(.client):\(.source)"}],
    # tables used only through DB::table() have no model/migration: keep them, columns unknown
    tables: [$m.tables[] as $t | ([($D[$backend].models.tables // [])[] | select(.name == $t)] | first) as $x |
      if $x then ($x | {name, models: (.models | map(short)), columns: (if (.columns | length) == 0 then null else .columns end), migrations: (.migrations | length)})
      else {name: $t, models: [], columns: null, migrations: 0} end],
    external_systems: [$m.external_systems[] as $sys | $repos[] as $repo | (($D[$repo].externals.systems // [])[] | select(.system == $sys)) |
      {system: $sys, repo: $repo, where: [.files[] | select(.file as $f | any($m.repos[] | select(.repo == $repo) | .files[]; . as $p | $f == $p or ($f | startswith($p | sub("/?$"; "/"))))) | "\($repo):\(.file):\(.lines[0:3] | map(tostring) | join(","))"]} | select(.where | length > 0)],
    environment: {source: "atreya-docs/environments.md",
      repos: [rows($env) as $E | $repos[] as $r | select(any($E[]; .[1] == $r)) |
        {repo: $r, columns: ([$E[] | select(.[0] == "H" and .[1] == $r)][0][2:] // []),
         rows: [$E[] | select(.[0] == "R" and .[1] == $r) | .[2:]]}]},
    languages: {required: ["English", "Marathi", "Hindi", "Czech", "German", "Spanish", "Italian"], required_source: "references/qa-scope-rules.md",
      files: [rows($langs)[] | "\(.[0]):\(.[1])"]}
  }' > "$OUTD/facts.json" || die "could not build facts"

"$JQ" -r '
  def cells: map(tostring) | join(" | ");
  "# Fact pack: \(.module.id) (\(.module.name))\n",
  "Generated \(.generated) by scripts/module-facts.sh. Product \(.module.product), critical \(.module.critical). Every line below is from code or a human-owned doc; cite the source given.\n",
  "Commits: " + (.commits | to_entries | map("\(.key) `\(.value)`") | join(", ")), "",
  "## Backend routes (\(.backend_routes | length))\n",
  (.backend_routes[] |
    "### \(.method) \(.uri)", "- controller: \(.controller) (\(.controller_status // "n/a")) · route: `\(.source)` · middleware: \(.middleware | join(", ") | if . == "" then "none" else . end)\(if .name then " · name: \(.name)" else "" end)",
    "- called by: \(if (.called_by | length) == 0 then "no screen in this workspace" else (.called_by | map("\(.client) \(.caller)" + (if (.pages | length) > 0 then " (" + (.pages[0:4] | join(", ")) + ")" else "" end)) | join("; ")) end)",
    (if (.validation | length) > 0 then "- validation: " + (.validation | map("`\(.field)`: \(.rules) (`\(.source)`)") | join("; ")) else empty end),
    (if (.errors | length) > 0 then "- errors: " + (.errors[0:8] | map("\(.http // "?") \"\(.message)\" (`\(.source)`)") | join("; ")) else empty end), ""),
  "## Backend routes no screen calls\n", (if (.not_called | length) == 0 then "None." else (.not_called | map("`\(.)`") | join(", ")) end), "",
  "## Web routes (\(.web_routes | length))\n", (.web_routes[] | "- \(.repo) `\(.key)` → \(.controller) · `\(.source)`\(if (.middleware | length) > 0 then " · " + (.middleware | join(", ")) else "" end)"), "",
  "## Screens (\(.screens | length))\n", (.screens[] | "- \(.repo) **\(.id)** `\(.file)`" + (if (.routes | length) > 0 then " · route " + (.routes | map(if type == "object" then .path else . end) | join(", ")) else "" end) + (if (.rendered_by | length) > 0 then " · rendered by " + (.rendered_by | join(", ")) else "" end) + (if (.links_to | length) > 0 then " · goes to " + (.links_to | map(.path // .route // .name // .url) | map(select(. != null)) | unique | join(", ")) else "" end)), "",
  "## API calls (\(.api_calls | length))\n", "| Client | Caller | Call | Route | Status | Source |", "|---|---|---|---|---|---|",
  (.api_calls | unique_by(.client, .caller, .endpoint)[] | "| \(.client) | \(.caller) | \(.method // "?") `\(.endpoint)` | \(.route // "-") | \(.status) | `\(.source)` |"), "",
  "## Tables (\(.tables | length))\n", (.tables[] | "- `\(.name)` (models: \(.models | join(", "))): " + (if .columns == null then "columns not in migrations" else (.columns | map(.name) | join(", ")) end)), "",
  "## External systems\n", (if (.external_systems | length) == 0 then "None found in the module files." else (.external_systems[] | "- \(.system) (\(.repo)): " + (.where[0:5] | map("`\(.)`") | join(", "))) end), "",
  "## Environment matrix (verbatim from \(.environment.source))\n",
  (.environment.repos[] | "### \(.repo)\n", ("| " + (.columns | cells) + " |"), ("|" + ([.columns[] | "---"] | join("|")) + "|"),
    (.rows[] | "| \(cells) |"), ""),
  "## Languages\n", "Required: \(.languages.required | join(", ")) (source: \(.languages.required_source)).", "Language files in code: \(if (.languages.files | length) == 0 then "none" else (.languages.files | join(", ")) end)"
' "$OUTD/facts.json" > "$OUTD/facts.md"

"$JQ" -r '"facts: \(.module.id): \(.backend_routes | length) backend routes (\([.backend_routes[] | select((.validation | length) > 0)] | length) with validation rules, \([.backend_routes[] | select((.errors | length) > 0)] | length) with error messages), \(.web_routes | length) web routes, \(.screens | length) screens, \(.api_calls | length) API calls, \(.tables | length) tables, \(.external_systems | length) external-system uses, \(.not_called | length) routes not called"' "$OUTD/facts.json"
echo "wrote $OUTD/facts.json and facts.md"
