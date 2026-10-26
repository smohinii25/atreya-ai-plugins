#!/bin/bash
# impact-facts.sh [--root R] --ticket SLUG [seeds...]
#
# Expands the SEEDS of a change (what Claude found the ticket touches) into the
# impact facts, deterministically, from modules.yaml and _map/:
#   --file  Repo:path[:line]   a changed file; with a line: the controller method
#                              around it, or the route defined on that line
#   --route "METHOD uri"       a changed backend route (key as in routes.json)
#   --table NAME               a table whose structure or meaning changes
#   --screen Repo:ScreenId     a changed screen (id as in _map/<repo>/screens.json)
#   --module ID                a module changed as a whole
# Writes atreya-docs/dev/SLUG/impact-facts.json and impact-facts.md:
# direct / related modules (with why), changed backend and web routes
# (controller, tables, every client caller), client API calls, screens, tables
# (changed vs only read), external systems used inside the changed code, docs and
# diagrams whose citations point into the changed code (requirement IDs, BRD
# rows, diagram names), risk signals + suggested level, QA to rerun
# (references/impact-guide.md). Warns when _map/ is behind a repo's HEAD.
# Exit 1 on an unknown seed (nothing is written).
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
SLUG=""; FILES=(); ROUTES=(); TABLES=(); SCREENS=(); MODS=()
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do case "$1" in
  --ticket) SLUG="$2"; shift 2 ;; --file) FILES+=("$2"); shift 2 ;; --route) ROUTES+=("$2"); shift 2 ;;
  --table) TABLES+=("$2"); shift 2 ;; --screen) SCREENS+=("$2"); shift 2 ;; --module) MODS+=("$2"); shift 2 ;;
  *) die "unknown argument $1" ;; esac; done
case "$SLUG" in ""|*[!A-Za-z0-9._-]*|.*) die "usage: impact-facts.sh --root R --ticket SLUG [--file Repo:path[:line]] [--route \"METHOD uri\"] [--table T] [--screen Repo:Id] [--module ID]" ;; esac
[ $(( ${#FILES[@]} + ${#ROUTES[@]} + ${#TABLES[@]} + ${#SCREENS[@]} + ${#MODS[@]} )) -gt 0 ] || die "give at least one seed"
[ -f "$DOCS/modules.yaml" ] || die "no modules.yaml (run /atreya:map --merge)"
OUT="$DOCS/dev/$SLUG"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atreya-impact.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT

# ---- seed files: tracked, not secret
for f in ${FILES[@]+"${FILES[@]}"}; do
  repo=${f%%:*}; rest=${f#*:}; path=${rest%%:*}
  [ "$repo" != "$f" ] && [ -n "$path" ] || die "bad --file '$f' (want Repo:path[:line])"
  [ -d "$ROOT/repos/$repo" ] || die "unknown repo in --file '$f'"
  is_secret_name "$path" && die "--file '$f' is a secret file; never used as a seed"
  git -C "$ROOT/repos/$repo" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || die "--file '$f': not a tracked file"
  [ "$rest" = "$path" ] || case "${rest#*:}" in ""|*[!0-9]*) die "bad line in --file '$f'" ;; esac
done

# ---- data: modules + every repo's map files, one object per repo
bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml" > "$TMPD/modules.json" || die "modules.yaml does not parse"
: > "$TMPD/parts"
for d in "$DOCS"/_map/*/; do
  r=$(basename "$d"); [ "$r" = _modules ] && continue
  for k in routes controllers models screens externals api-links; do
    [ -f "$d$k.json" ] && "$JQ" -c --arg r "$r" --arg k "$k" '{r: $r, k: $k, d: .}' "$d$k.json" >> "$TMPD/parts"
  done
  head=$(git -C "$ROOT/repos/$r" rev-parse HEAD 2>/dev/null || echo "")
  printf '{"r":"%s","k":"head","d":"%s"}\n' "$r" "$head" >> "$TMPD/parts"
done
"$JQ" -s 'reduce .[] as $x ({}; .[$x.r][$x.k] = $x.d)' "$TMPD/parts" > "$TMPD/data.json"

"$JQ" -n --arg ticket "$SLUG" \
  --argjson files "$(printf '%s\n' ${FILES[@]+"${FILES[@]}"} | "$JQ" -R -s -c 'split("\n") | map(select(. != "") | split(":") | {repo: .[0], path: .[1], line: (if length > 2 then (.[2] | tonumber) else null end)})')" \
  --argjson routes "$(printf '%s\n' ${ROUTES[@]+"${ROUTES[@]}"} | "$JQ" -R -s -c 'split("\n") | map(select(. != ""))')" \
  --argjson tables "$(printf '%s\n' ${TABLES[@]+"${TABLES[@]}"} | "$JQ" -R -s -c 'split("\n") | map(select(. != ""))')" \
  --argjson screens "$(printf '%s\n' ${SCREENS[@]+"${SCREENS[@]}"} | "$JQ" -R -s -c 'split("\n") | map(select(. != "") | {repo: (split(":")[0]), id: (split(":")[1:] | join(":"))})')" \
  --argjson mods "$(printf '%s\n' ${MODS[@]+"${MODS[@]}"} | "$JQ" -R -s -c 'split("\n") | map(select(. != ""))')" \
  '{ticket: $ticket, files: $files, routes: $routes, tables: $tables, screens: $screens, modules: $mods}' > "$TMPD/seeds.json"

# ---- expansion (everything after the seeds is derived)
"$JQ" -n --slurpfile Mf "$TMPD/modules.json" --slurpfile Df "$TMPD/data.json" --slurpfile Sf "$TMPD/seeds.json" '
  def short: split("\\") | last;
  def uniq: unique;
  def same($a; $b): ($a // "" | ascii_downcase) == ($b // "" | ascii_downcase);  # PHP class and method names ignore case
  $Mf[0] as $M | $Df[0] as $D | $Sf[0] as $S | $M.backend as $be |
  def routesof($r): [($D[$r].routes.routes // [])[] | select(.shadowed != true)];
  def routefiles($r): [($D[$r].routes.route_files // [])[].file];
  def ctrls($r): ($D[$r].controllers.controllers // []);
  def links($r): ($D[$r]["api-links"].links // []);
  def kind($r): ($D[$r].screens.kind // "");
  def methodspan($r; $fqcn; $name): ([ctrls($r)[] | select(same(.fqcn; $fqcn)) | .methods[] | select(same(.name; $name)) | .lines] | .[0]);

  # -- seed spans
  [ $S.files[] as $f | $f.repo as $r |
    if (routefiles($r) | index($f.path)) and $f.line != null then
      {repo: $r, path: $f.path, from: $f.line, to: $f.line, kind: "route-line",
       routes: [routesof($r)[] | select(.file == $f.path and .line == $f.line) | .key]}
    else
      ([ctrls($r)[] | select(.file == $f.path)] | .[0]) as $c |
      if $c != null then
        (if $f.line == null then $c.methods else [$c.methods[] | select(.lines[0] <= $f.line and $f.line <= .lines[1])] end) as $ms |
        if $f.line != null and ($ms | length) == 0 then {repo: $r, path: $f.path, from: $f.line, to: $f.line, kind: "line", fqcn: $c.fqcn, methods: []}
        elif $f.line == null then {repo: $r, path: $f.path, from: 0, to: 1000000000, kind: "file", fqcn: $c.fqcn, methods: [$ms[].name]}
        else {repo: $r, path: $f.path, from: $ms[0].lines[0], to: $ms[0].lines[1], kind: "method", fqcn: $c.fqcn, methods: [$ms[].name]} end
      else {repo: $r, path: $f.path, from: ($f.line // 0), to: ($f.line // 1000000000), kind: (if $f.line == null then "file" else "line" end)} end
    end ] as $seedspans |

  # -- changed routes (any Laravel repo; backend ones are "backend routes")
  ([ $seedspans[] | . as $s |
     (if .kind == "route-line" then [routesof($s.repo)[] | select(.key as $k | $s.routes | index($k))]
      elif .fqcn != null then [routesof($s.repo)[] | select(same(.controller; $s.fqcn) and (.action as $a | any($s.methods[]; same(.; $a))))]
      else [] end)[] | {repo: $s.repo} + . ] +
   [ $S.routes[] as $k | routesof($be)[] | select(.key == $k) | {repo: $be} + . ]) | unique_by(.repo + " " + .key) as $chr |
  ($S.routes - [$chr[] | select(.repo == $be) | .key]) as $badroutes |

  # -- spans of changed routes: definition line + controller method
  ([ $chr[] | {repo, path: .file, from: .line, to: .line, kind: "route-line"},
     (if .controller != null then (methodspan(.repo; .controller; .action)) as $l |
        if $l != null then {repo, path: .controller_file, from: $l[0], to: $l[1], kind: "method"} else empty end
      else empty end) ]) as $routespans |

  # -- client calls made from changed client code (seed spans, changed web-route methods)
  ([ ($D | keys[]) as $r | links($r)[] | . as $l |
     ($l.source | split(":")) as $sp | ($sp[1] | tonumber? // null) as $ln |
     select(any(($seedspans + $routespans)[]; .repo == $r and .path == $sp[0] and ($ln == null or (.from <= $ln and $ln <= .to))))
     | {client: $r, caller, route, module, status, source: "\($r):\($l.source)", pages} ] | unique_by(.source + " " + (.route // ""))) as $calls |

  # -- tables: changed (seeds, seeded models/migrations) vs read by changed backend routes
  ([ $S.tables[],
     ($seedspans[] as $s | ($D[$s.repo].models.models // [])[] | select(.file == $s.path) | .table // empty),
     ($seedspans[] as $s | ($D[$s.repo].models.tables // [])[] | select(.migrations // [] | index($s.path)) | .name) ] | uniq) as $chtables |
  ($S.tables - ([($D[$be].models.tables // [])[].name] + [$M.modules[].tables[]] | uniq)) as $badtables |
  ([ $chr[] | select(.repo == $be and .controller != null) | . as $x |
     ctrls($be)[] | select(same(.fqcn; $x.controller)) | .methods[] | select(same(.name; $x.action)) | .tables[] ] | uniq - $chtables) as $readtables |
  def users($t): [$M.modules[] | select(.tables | index($t)) | .id];

  # -- screens
  ([ $seedspans[] as $s | ($D[$s.repo].screens.screens // [])[] | select(.file == $s.path) | {repo: $s.repo, id, file} ] +
   [ $S.screens[] as $q | ($D[$q.repo].screens.screens // [])[] | select(.id == $q.id) | {repo: $q.repo, id, file} ] +
   [ $chr[] | select(.repo != $be) as $w | ($D[$w.repo].screens.screens // [])[] |
     select(any(.rendered_by[]?; same(.controller; $w.controller) and same(.method; $w.action))) | {repo: $w.repo, id, file} ]
   | unique_by(.repo + " " + .id)) as $chscreens |
  ($S.screens - [$chscreens[] | {repo, id}] | map("\(.repo):\(.id)")) as $badscreens |
  ([ $chr[] | select(.repo == $be) | .key as $k | ($D | keys[]) as $r | links($r)[] | select(.route == $k)
     | {route: $k, client: $r, caller, caller_module, pages, source: "\($r):\(.source)"} ] | unique_by(.route + " " + .source)) as $callers |

  # -- modules
  def owns_file($m; $r; $p): any($m.repos[]; .repo == $r and ((.files | index($p)) or any(.paths[]; . as $x | $p | startswith($x)))) or any($m.screens[]; .repo == $r and .path == $p);
  ([ $M.modules[] as $m |
     ([ ($S.modules | index($m.id) | if . != null then "changed as a whole (seed)" else empty end),
        ($seedspans[] | select(owns_file($m; .repo; .path)) | "owns \(.repo):\(.path)"),
        ($chr[] | select(.repo == $be and (.key as $k | $m.routes | index($k))) | "owns route \(.key)"),
        ($chr[] | select(.repo != $be) as $w | select(any($m.web_routes[]; .repo == $w.repo and (.routes | index($w.key)))) | "owns web route \($w.repo) \($w.key)"),
        ($chscreens[] | select(owns_file($m; .repo; .file)) | "owns screen \(.repo):\(.id)") ] | uniq) as $why |
     select($why | length > 0) | {id: $m.id, name: $m.name, critical: ($m.critical == true), why: $why} ]) as $direct |
  ([ $M.modules[] as $m | select([$direct[].id] | index($m.id) | not) |
     ([ ($chtables[] | select(. as $t | $m.tables | index($t)) | "uses changed table \(.)"),
        ($callers[] | select(.caller_module == $m.id) | "calls \(.route) (\(.client))"),
        ($calls[] | select(.module == $m.id) | "owns \(.route), called by changed \(.client) code") ] | uniq) as $why |
     select($why | length > 0) | {id: $m.id, name: $m.name, critical: ($m.critical == true), why: $why} ]) as $related |
  ($S.modules - [$M.modules[].id]) as $badmods |

  # -- external systems used inside the changed code
  ([ ($D | keys[]) as $r | ($D[$r].externals.systems // [])[] as $x | $x.files[] as $xf |
     [ $xf.lines[] as $ln | select(any(($seedspans + $routespans)[]; .repo == $r and .path == $xf.file and .from <= $ln and $ln <= .to)) | $ln ] as $hit |
     select($hit | length > 0) | {system: $x.system, repo: $r, where: "\($r):\($xf.file):\($hit | map(tostring) | join(","))"} ]) as $ext |

  # -- risk (references/impact-guide.md)
  ([$direct[] | select(.critical) | "critical module \(.id)"] +
   [$ext[] | select(.system == "Razorpay" or .system == "ENACH") | "\(.system) code in the change (\(.where))"] +
   [$chtables[] | select((users(.) | length) >= 3) | "changed table \(.) is used by \(users(.) | length) modules"] +
   (if ($direct | length) >= 4 then ["\($direct | length) modules changed"] else [] end)) as $high |
  ((if ($direct | length) >= 2 and ($direct | length) <= 3 then ["\($direct | length) modules changed"] else [] end) +
   [$chr[] | select(.repo == $be) | .key as $k | select(([$callers[] | select(.route == $k) | kind(.client)] | uniq) as $ks | ($ks | index("flutter")) and ($ks | index("blade"))) | "route \($k) is called by web and app"] +
   [$chtables[] | select((users(.) | length) == 2) | "changed table \(.) is shared by 2 modules"] +
   ([$ext[].system] | uniq | map("uses external system \(.)"))) as $medium |
  (if ($direct + $related | length) == 0 then "TBD" elif ($high | length) > 0 then "High" elif ($medium | length) > 0 then "Medium" else "Low" end) as $level |

  # -- QA (web staging only)
  ([$chscreens[] | select(kind(.repo) == "flutter") | .id] + [$callers[] | select(kind(.client) == "flutter") | .pages[]] + [$calls[] | select(kind(.client) == "flutter") | .pages[]?] | uniq) as $app |
  def web($id): ($M.modules[] | select(.id == $id)) as $m | (($m.web_routes | map(.routes | length) | add // 0) > 0) or any($m.screens[]; kind(.repo) == "blade");
  { ticket: $S.ticket,
    errors: ([$badroutes[] | "unknown route \(.)"] + [$badtables[] | "unknown table \(.)"] + [$badscreens[] | "unknown screen \(.)"] + [$badmods[] | "unknown module \(.)"]),
    commits: ($D | with_entries(.value = .value.head)),
    map_behind: [ $D | to_entries[] | (.value.routes.commit // .value.screens.commit) as $c | select($c != null and .value.head != "" and $c != .value.head) | "\(.key): _map built from \($c[0:10]), HEAD is \(.value.head[0:10])" ],
    seeds: $S, spans: ($seedspans + $routespans | unique_by("\(.repo):\(.path):\(.from)-\(.to)")),
    direct_modules: $direct, related_modules: $related,
    backend_routes: [ $chr[] | select(.repo == $be) | .key as $k | . as $x |
      {key, controller: (if .controller then "\(.controller | short)@\(.action)" else .action end), source: "\($be):\(.file):\(.line)",
       controller_source: (if .controller_file then "\($be):\(.controller_file)" else null end), middleware,
       tables: [ctrls($be)[] | select(same(.fqcn; $x.controller)) | .methods[] | select(same(.name; $x.action)) | .tables[]] | uniq,
       callers: [$callers[] | select(.route == $k) | {client, caller, pages, source}]} ],
    web_routes: [ $chr[] | select(.repo != $be) | {repo, key, controller: (if .controller then "\(.controller | short)@\(.action)" else .action end), source: "\(.repo):\(.file):\(.line)"} ],
    client_calls: $calls,
    screens: { changed: $chscreens,
               web_pages: ([$chscreens[] | select(kind(.repo) == "blade") | "\(.repo):\(.id)"] + [$chr[] | select(.repo != $be) | "\(.repo):\(.key)"] + [$callers[] | select(kind(.client) == "blade") | .client as $c | .pages[] | "\($c):\(.)"] | uniq),
               app_screens: $app },
    tables: { changed: [$chtables[] | {name: ., modules: users(.)}], read: [$readtables[] | {name: ., modules: (users(.) | length)}] },
    external_systems: $ext,
    risk: {level: $level, high: $high, medium: $medium},
    qa: { sanity: [$direct[] | select(web(.id)) | .id],
          regression: [($direct + $related)[] | select(web(.id)) | .id],
          not_covered: ([($direct + $related)[] | select(web(.id) | not) | "\(.id) (no web pages: app or backend only)"] +
                        (if ($app | length) > 0 then ["app screens (QA tests web only): \($app | join(", "))"] else [] end)) } }
' > "$TMPD/facts.json" || die "expansion failed (bug)"

ERR=$("$JQ" -r '.errors[]' "$TMPD/facts.json")
[ -z "$ERR" ] || die "$(printf 'unknown seed(s):\n%s' "$ERR")"

# ---- docs and diagrams whose citations point into the changed code
: > "$TMPD/cites.tsv"
for m in $("$JQ" -r '(.direct_modules + .related_modules)[].id' "$TMPD/facts.json"); do
  ND="$DOCS/nt/$m"
  for d in PRD BRD staging-delta; do
    [ -f "$ND/$d.md" ] || continue
    awk -v doc="nt/$m/$d.md" '
      /^## [0-9]+\./ { sec = "§" $2; sub(/\.$/, "", sec); item = sec; next }
      /^### / { item = $2; sub(/:$/, "", item); next }
      { where = item; if (match($0, /^\| *BR-[0-9]+/)) { where = substr($0, RSTART, RLENGTH); sub(/^\| */, "", where) }
        line = $0
        while (match(line, /`[A-Za-z0-9_.-]+:[A-Za-z0-9_.\/{}@-]+(:[0-9]+([,-][0-9]+)*)?`/)) {
          c = substr(line, RSTART + 1, RLENGTH - 2); print doc "\t" where "\t" c; line = substr(line, RSTART + RLENGTH) } }' "$ND/$d.md" >> "$TMPD/cites.tsv"
  done
  for s in "$ND"/diagrams/*.spec.json; do
    [ -f "$s" ] || continue
    n=$(basename "$s" .spec.json)
    "$JQ" -r --arg doc "nt/$m/diagrams/$n.drawio" '[.nodes[], .edges[]] | .[] | select(.source != null and .source != "") | "\($doc)\t\(.label // .id | gsub("[\t\n]+"; " "))\t\(.source)"' "$s" >> "$TMPD/cites.tsv"
  done
done
"$JQ" -R -s --slurpfile F "$TMPD/facts.json" '
  ($F[0].spans) as $sp |
  [ split("\n")[] | select(. != "") | split("\t") | {doc: .[0], where: .[1], cite: .[2]} |
    (.cite | split(":")) as $c | (($c[2] // "") | if . == "" then null else (split(",")[0] | split("-")[0] | tonumber? // null) end) as $ln |
    [$sp[] | select(.repo == $c[0] and .path == $c[1] and ($ln == null or (.from <= $ln and $ln <= .to))) | .kind] as $k |
    select($k | length > 0) |
    # a hit only on a route definition line means "lists the route", not "describes the changed code"
    (if all($k[]; . == "route-line") then .where += " (route line only)" else . end) ]
  | group_by(.doc) | map({doc: .[0].doc,
      where: ([.[].where] | unique | (map(select(endswith(" (route line only)") | not)) as $code | map(select(endswith(" (route line only)") and (rtrimstr(" (route line only)") as $w | $code | index($w) | not))) + $code) | unique),
      cites: ([.[].cite] | unique | .[0:8])})
  | $F[0] + {docs: .}' "$TMPD/cites.tsv" > "$TMPD/facts2.json" || die "doc scan failed (bug)"

mkdir -p "$OUT" || die "cannot create $OUT"
"$JQ" 'del(.errors)' "$TMPD/facts2.json" | redact > "$OUT/impact-facts.json"
"$JQ" -r '
  def l($x): if ($x | length) == 0 then "- none" else ($x[] | "- \(.)") end;
  "# Impact facts: \(.ticket)\n",
  "Generated by scripts/impact-facts.sh from modules.yaml and _map/ (deterministic). Claude writes impact.md from this.\n",
  (if (.map_behind | length) > 0 then "**Warning: _map is behind HEAD** (run /atreya:map for these repos first):\n\(.map_behind | map("- \(.)") | join("\n"))\n" else empty end),
  "## Seeds",
  ([.seeds.files[] | "- file `\(.repo):\(.path)\(if .line then ":\(.line)" else "" end)`"] + [.seeds.routes[] | "- route `\(.)`"] + [.seeds.tables[] | "- table `\(.)`"] + [.seeds.screens[] | "- screen \(.repo):\(.id)"] + [.seeds.modules[] | "- module \(.)"] | join("\n")),
  "\n## Changed code spans",
  l([.spans[] | select(.kind != "route-line") | "`\(.repo):\(.path)` \(if .to >= 1000000000 then "whole file" elif .from == .to then "line \(.from)" else "lines \(.from)-\(.to)" end) (\(.kind))"]),
  "### Route definitions of the changed routes (context)",
  l([.spans[] | select(.kind == "route-line") | "`\(.repo):\(.path):\(.from)`"]),
  "\n## Modules\n### Direct",
  (if (.direct_modules | length) == 0 then "- none" else (.direct_modules | map("- **\(.id)**\(if .critical then " (critical)" else "" end): \(.why | join("; "))") | join("\n")) end),
  "### Related",
  (if (.related_modules | length) == 0 then "- none" else (.related_modules | map("- **\(.id)**\(if .critical then " (critical)" else "" end): \(.why | join("; "))") | join("\n")) end),
  "\n## Backend routes changed",
  (if (.backend_routes | length) == 0 then "- none" else (.backend_routes[] | "- `\(.key)` → \(.controller) (`\(.source)`); tables: \(.tables | join(", ") | if . == "" then "none" else . end)\n" + (.callers | map("  - called by \(.client) \(.caller) (`\(.source)`) pages: \(.pages | join(", ") | if . == "" then "none found" else . end)") | join("\n") | if . == "" then "  - no client in this workspace calls it" else . end)) end),
  "\n## Web routes changed", l([.web_routes[] | "`\(.repo) \(.key)` → \(.controller) (`\(.source)`)"]),
  "\n## API calls from changed client code", l([.client_calls[] | "\(.client) \(.caller) → `\(.route // "unresolved")` (\(.module // "?")) at `\(.source)`"]),
  "\n## Screens", "### Changed", l([.screens.changed[] | "\(.repo):\(.id) (`\(.repo):\(.file)`)"]),
  "### Web pages to check", l(.screens.web_pages), "### App screens affected", l(.screens.app_screens),
  "\n## Tables", "### Changed", l([.tables.changed[] | "`\(.name)` used by: \(.modules | join(", ") | if . == "" then "no module" else . end)"]),
  "### Read by changed routes (context)", l([.tables.read[] | "`\(.name)` (\(.modules) modules)"]),
  "\n## External systems in the changed code", l([.external_systems[] | "\(.system): `\(.where)`"]),
  "\n## Docs and diagrams citing the changed code", l([.docs[] | "\(.doc): \(.where | join(", "))"]),
  "\n## Risk (suggested): \(.risk.level)", "High signals:", l(.risk.high), "Medium signals:", l(.risk.medium),
  "\n## QA to rerun (web staging only)", "- Sanity: \(.qa.sanity | join(", ") | if . == "" then "none" else . end)",
  "- Regression: \(.qa.regression | join(", ") | if . == "" then "none" else . end)",
  (if (.qa.not_covered | length) == 0 then "- Not covered by QA: none" else "- Not covered by QA:\n" + (.qa.not_covered | map("  - \(.)") | join("\n")) end)
' "$OUT/impact-facts.json" | redact > "$OUT/impact-facts.md"
"$JQ" -r '"impact-facts: \(.ticket): \(.direct_modules | length) direct + \(.related_modules | length) related modules, \(.backend_routes | length) backend routes (\([.backend_routes[].callers[]] | length) client callers), \(.web_routes | length) web routes, \(.client_calls | length) API calls from changed client code, \(.tables.changed | length) changed tables, \(.external_systems | length) external uses, \(.docs | length) docs/diagrams cite it; risk \(.risk.level)\(if (.map_behind | length) > 0 then "; WARNING _map behind HEAD for \(.map_behind | length) repo(s)" else "" end)"' "$OUT/impact-facts.json"
echo "wrote $OUT/impact-facts.json and impact-facts.md"
