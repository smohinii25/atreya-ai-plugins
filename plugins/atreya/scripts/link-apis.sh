#!/bin/bash
# link-apis.sh [--root R] [--module ID] [--update-not-in-use]
#
# Joins every client call (_map/<client>/calls.json) to a backend route:
#   screen/page -> METHOD + endpoint -> route -> controller@method -> models/tables
# Writes _map/<client>/api-links.json + api-links.md for each client and
# _map/<backend>/api-links.md with "routes no screen calls" per module.
# Two lists with counts: calls with no matching route, routes no screen calls.
# --module ID          also print that module's summary
# --update-not-in-use  refresh ONLY the block between
#                      <!-- link-apis:start --> and <!-- link-apis:end -->
#                      in atreya-docs/not-in-use.md (NT modules only).
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
MOD=""; UPD=0
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do case "$1" in --module) MOD="$2"; shift 2 ;; --update-not-in-use) UPD=1; shift ;; *) die "unknown argument $1" ;; esac; done
[ -f "$DOCS/modules.yaml" ] || die "no modules.yaml (run /atreya:map --merge first)"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atreya-links.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT
bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml" > "$TMPD/modules.json" || exit 1
BACKEND=$("$JQ" -r '.backend' "$TMPD/modules.json")
BD="$DOCS/_map/$BACKEND"
for f in routes controllers; do [ -f "$BD/$f.json" ] || die "run /atreya:map $BACKEND first ($f.json missing)"; done
[ -z "$MOD" ] || "$JQ" -e --arg m "$MOD" '.modules | any(.id == $m)' "$TMPD/modules.json" >/dev/null || die "unknown module $MOD"

CLIENTS=""
for d in "$DOCS"/_map/*/; do c=${d%/}; c=${c##*/}; [ "$c" != "$BACKEND" ] && [ -f "$d/calls.json" ] && CLIENTS="$CLIENTS $c"; done
[ -n "$CLIENTS" ] || die "no calls.json yet (run calls.sh for the client repos)"

# ---- manual fixes (human-owned; read on every run, never rewritten)
OVF="$DOCS/_map/overrides.yaml"
if [ ! -f "$OVF" ]; then
  cat > "$OVF" <<'EOF'
# overrides.yaml: manual fixes for links the scripts cannot resolve.
# Human-owned: scripts/link-apis.sh reads it on every run and never changes it.
# One entry per call site; "source" exactly as listed under "Calls with no page"
# or "Unresolved" in _map/<client>/api-links.md. Example:
#   - client: "Nadi-Tarangini-Frontend"
#     source: "public/js/common.js:120"   # JS call site, PHP call or Dart call
#     pages:                                # page / screen ids that trigger it
#       - "auth.login"
#     path: "/verify-login-otp"             # optional: URL of an unresolved JS call
#     method: "POST"                        # optional, with path
#     note: "who checked it, and how"
links: []
EOF
  echo "created $OVF (empty)"
fi
bash "$ATREYA_SCRIPTS/yaml2json.sh" "$OVF" > "$TMPD/overrides.json" || die "overrides.yaml does not parse (see the line above)"
BAD=$("$JQ" -r '[(.links // [])[] | select((.client | type) != "string" or (.source | type) != "string" or ((.pages // []) | type) != "array") | "\(.source // "?")"] | join(", ")' "$TMPD/overrides.json")
[ -z "$BAD" ] || die "overrides.yaml: each entry needs client, source and (optional) a pages list: $BAD"

# ---- per client
for C in $CLIENTS; do
  CD="$DOCS/_map/$C"
  f_or_null() { [ -f "$1" ] && echo "$1" || echo /dev/null; }
  "$JQ" -n --slurpfile calls "$CD/calls.json" --slurpfile br "$BD/routes.json" --slurpfile bc "$BD/controllers.json" \
     --slurpfile cr "$(f_or_null "$CD/routes.json")" --slurpfile cs "$(f_or_null "$CD/screens.json")" \
     --slurpfile mods "$TMPD/modules.json" --slurpfile ovf "$TMPD/overrides.json" '
    def lc: ascii_downcase;
    def segs: ltrimstr("/") | rtrimstr("/") | split("/");
    def param: test("^\\{.*\\}$");
    $calls[0] as $K | $br[0] as $B | ($cr[0] // null) as $CR | ($cs[0] // null) as $CS | $mods[0] as $M |
    [($ovf[0].links // [])[] | select(.client == $K.repo)] as $OV |
    def ov($src): [$OV[] | select(.source == $src)] | first;
    def byLen($routes): [$routes[] | select(.shadowed | not) | . + {s: (.uri | segs)}] | group_by(.s | length) | map({key: (.[0].s | length | tostring), value: .}) | from_entries;
    byLen($B.routes) as $byLen |
    byLen($CR.routes // []) as $byLenF |
    ([$bc[0].controllers[] as $k | $k.methods[] | {key: (($k.fqcn | lc) + "@" + (.name | lc)), value: {models, tables}}] | from_entries) as $mt |
    ([$M.modules[] as $m | $m.routes[] | {key: ., value: $m.id}] | from_entries) as $modOfRoute |
    ([$M.modules[] as $m | ($m.web_routes[]? | select(.repo == $K.repo) | .routes[] | {key: ., value: $m.id}), ($m.screens[]? | select(.repo == $K.repo) | {key: .path, value: $m.id})] | from_entries) as $modOfClient |
    def match_in($idx; $path; $method):
      ($path | segs) as $cs |
      [($idx[$cs | length | tostring] // [])[] | . as $r |
        select([range(0; $cs | length) as $i | ($r.s[$i] == $cs[$i]) or ($r.s[$i] | param)] | all)] as $cand |
      ([$cand[] | select(.method == $method or .method == "ANY" or $method == null)] | sort_by([.s[] | select(param)] | length)) as $ok |
      if ($ok | length) > 0 then {status: "matched", route: $ok[0]}
      elif ($cand | length) > 0 then {status: "method-mismatch", route: $cand[0], route_methods: ([$cand[].method] | unique)}
      else {status: "no-route", route: null} end;
    def match_route($c): match_in($byLen; $c.path; $c.method);
    def backend_fields($m):
      { status: $m.status, route: (if $m.route then $m.route.key else null end), route_methods: ($m.route_methods // null),
        controller: (if $m.route and $m.route.controller then (($m.route.controller | split("\\") | last) + "@" + ($m.route.action // "")) else null end),
        models: (if $m.route and $m.route.controller then ($mt[(($m.route.controller | lc) + "@" + ($m.route.action // "" | lc))].models // []) | map(split("\\") | last) else [] end),
        tables: (if $m.route and $m.route.controller then ($mt[(($m.route.controller | lc) + "@" + ($m.route.action // "" | lc))].tables // []) else [] end),
        module: (if $m.route then ($modOfRoute[$m.route.key] // null) else null end) };
    # ---- Laravel client: page JS calls (screens.sh) -> Frontend route, with overrides
    ([($CS.js_calls // [])[] | ("\(.file):\(.line)") as $src | ov($src) as $o | . + {source: $src} |
       if $o then . + {pages: ($o.pages // .pages), url: ($o.path // .url), method: ($o.method // .method), how: "override",
                       unresolved: (if (($o.pages // .pages) | length) > 0 then null else .unresolved end)} else . end] +
     [($CS.js_unresolved // [])[] | ("\(.file):\(.line)") as $src | ov($src) as $o | select($o and $o.path) |
       {file, line, source: $src, method: ($o.method // null), url: $o.path, context: "override", pages: ($o.pages // []), how: "override",
        unresolved: (if (($o.pages // []) | length) > 0 then null else "override gives the URL but no pages" end)}]) as $jsc0 |
    ([($CR.routes // [])[] | select(.name != null) | {key: .name, value: .}] | from_entries) as $fbyname |
    [$jsc0[] | . as $j |
      (if ($j.url | startswith("R:")) then ($fbyname[$j.url[2:]] // null) else (match_in($byLenF; $j.url; $j.method) | if .status == "matched" then .route else null end) end) as $fr |
      $j + (if $fr then {target: "web", web_route: $fr.key}
            else (match_route({path: ($j.url | ltrimstr("R:")), method: $j.method})) as $bm |
                 if $bm.status == "matched" then {target: "backend", backend: $bm} else {target: "none"} end end)] as $jsc |
    ([$jsc[] | select(.target == "web")] | group_by(.web_route) | map({key: .[0].web_route, value: .}) | from_entries) as $trig |
    # form actions: the pages a form (or a partial holding it) is part of
    ([($CS.screens // [])[] | select(.parts) | {id, parts}]) as $pparts |
    ([($CS.forms // [])[] | . as $fm |
       (if ($fm.action | startswith("R:")) then ($fbyname[$fm.action[2:]].key // null) else (match_in($byLenF; $fm.action; null) | if .status == "matched" then .route.key else null end) end) as $k |
       select($k) | {key: $k, pages: [$pparts[] | select(.parts | index($fm.file)) | .id]}] | group_by(.key) | map({key: .[0].key, value: ([.[].pages[]] | unique)}) | from_entries) as $formp |
    [ $K.calls[] | select(.path != null) | . as $c | match_route($c) as $m | "\($c.file):\($c.line)" as $src |
      (if $K.kind == "laravel" then
         ([($CR.routes // [])[] | select((.controller // "" | lc) == ($c.controller // "" | lc) and (.action // "" | lc) == ($c.action // "" | lc)) | .key] | unique) as $web |
         ([($CS.screens // [])[] | select(any(.rendered_by[]?; (.controller | lc) == ($c.controller // "" | lc) and (.method | lc) == ($c.action // "" | lc))) | .id] | unique) as $views |
         ([$web[] | ($trig[.] // [])[]]) as $t |
         (($views + [$t[].pages[]] + [$web[] | ($formp[.] // [])[]]) | unique) as $pg |
         ([$t[] | select(.unresolved) | {source, reason: .unresolved}] | unique) as $un |
         {caller: "\(($c.controller // "?") | split("\\") | last)@\($c.action // "?")", web_routes: $web, pages: $pg,
          pages_unresolved: (if ($pg | length) == 0 and ($un | length) == 0 then
              [{source: $src, reason: (if ($web | length) == 0 then "controller method has no web route" else "no page found that calls \($web | join(", "))" end)}] else $un end),
          caller_module: ([$web[] | $modOfClient[.] // empty] | unique | first // null)}
       else
         {caller: ($c.dart_method // "?"), pages: ($c.screens // []),
          pages_unresolved: [($c.trace_unresolved // [])[] | {source: "\(.file):\(.line)", reason}],
          caller_module: ([($c.screen_files // [])[] | $modOfClient[.] // empty] | unique | first // null)}
       end) as $ctx |
      ov($src) as $o |
      { client: $K.repo, source: $src, method: $c.method, endpoint: $c.path } + backend_fields($m) +
      { caller: $ctx.caller, caller_module: $ctx.caller_module, web_routes: ($ctx.web_routes // null),
        pages: (if $o then ($o.pages // $ctx.pages) else $ctx.pages end),
        pages_unresolved: (if $o and (($o.pages // []) | length) > 0 then [] else $ctx.pages_unresolved end),
        pages_override: ($o != null) } ] as $links0 |
    # page JS that calls the backend directly (no Frontend route in between)
    ($links0 + [$jsc[] | select(.target == "backend") |
      { client: $K.repo, source: .source, method: .method, endpoint: (.url | ltrimstr("R:")) } + backend_fields(.backend) +
      { caller: "page JS (\(.context))", caller_module: null, web_routes: null, pages: .pages,
        pages_unresolved: (if .unresolved then [{source: .source, reason: .unresolved}] else [] end), pages_override: (.how == "override"), via: "js"}]) as $links |
    ([$links[].source] + [$jsc0[].source] + [($CS.js_unresolved // [])[] | "\(.file):\(.line)"] + [($K.calls // [])[] | "\(.file):\(.line)"]) as $known |
    {client: $K.repo, client_commit: $K.commit, backend: $B.repo, backend_commit: $B.commit,
     counts: {calls: ($K.calls | length), matched: ([$links0[] | select(.status == "matched")] | length),
              method_mismatch: ([$links0[] | select(.status == "method-mismatch")] | length),
              no_route: ([$links0[] | select(.status == "no-route")] | length),
              unresolved: $K.counts.unresolved,
              matched_with_page: ([$links0[] | select(.status == "matched" and (.pages | length) > 0)] | length),
              matched_without_page: ([$links0[] | select(.status == "matched" and (.pages | length) == 0)] | length),
              js_direct_backend: ([$links[] | select(.via == "js")] | length),
              js_no_route: ([$jsc[] | select(.target == "none")] | length),
              overrides_applied: ([$OV[] | select(.source as $s | $known | index($s))] | length),
              overrides_unused: ([$OV[] | select(.source as $s | $known | index($s) | not)] | length)},
     links: ($links | sort_by(.status != "matched", .caller, .endpoint, .source)),
     js_no_route: [$jsc[] | select(.target == "none") | {source, method, url, context}],
     js_unresolved: [($CS.js_unresolved // [])[] | ("\(.file):\(.line)") as $src | select((ov($src) // {}).path == null) | {source: $src, reason}],
     overrides_unused: [$OV[] | select(.source as $s | $known | index($s) | not) | .source],
     unresolved: $K.unresolved}' > "$CD/api-links.json" || die "could not link $C"

  "$JQ" -r '
    "# API links: \(.client) → \(.backend)\n",
    "Built from \(.client) `\(.client_commit)` and \(.backend) `\(.backend_commit)` by scripts/link-apis.sh.\n",
    "**\(.counts.calls) calls**: \(.counts.matched) matched (\(.counts.matched_with_page) with a page, \(.counts.matched_without_page) without), \(.counts.method_mismatch) method mismatch, \(.counts.no_route) with no matching route, \(.counts.unresolved) unresolved (URL not static).",
    (if .counts.js_direct_backend > 0 then "Page JS calling the backend directly: \(.counts.js_direct_backend)." else empty end),
    "Pages come from code only (views a call renders, page JS and forms that reach its route, the screen that sends its event); _map/overrides.yaml fixes the rest (\(.counts.overrides_applied) applied, \(.counts.overrides_unused) unused).\n",
    "| Screen / page | Caller | Method + endpoint | Route | Controller@method | Models / tables | Module | Source |", "|---|---|---|---|---|---|---|---|",
    (.links[] | select(.status == "matched") | "| \(if (.pages | length) == 0 then "*unresolved*" else (.pages | join(", ")) end)\(if .pages_override then " (override)" else "" end) | \(.caller) | \(.method // "?") `\(.endpoint)` | `\(.route)` | \(.controller // "closure") | \((.tables | join(", ")) // "") | \(.module // "unassigned") | `\(.source)` |"),
    "", "## Calls with no page (\(.counts.matched_without_page))\n",
    "Add a page by hand in `_map/overrides.yaml` (source = the call site below) once checked.\n",
    (if .counts.matched_without_page == 0 then "None." else
      ("| Caller | Method + endpoint | Why no page | Call site to override |", "|---|---|---|---|",
       (.links[] | select(.status == "matched" and (.pages | length) == 0) | . as $l |
         "| \(.caller) | \(.method // "?") `\(.endpoint)` | \(.pages_unresolved | map(.reason) | unique | join("; ")) | \(.pages_unresolved | map("`\(.source)`") | unique | join(", ")) |")) end),
    "", "## Calls with no matching route (\(.counts.no_route + .counts.method_mismatch))\n",
    (if (.counts.no_route + .counts.method_mismatch) == 0 then "None." else
      ("| Caller | Method + endpoint | Problem | Source |", "|---|---|---|---|",
       (.links[] | select(.status != "matched") | "| \(.caller) | \(.method // "?") `\(.endpoint)` | \(if .status == "method-mismatch" then "route exists only as \(.route_methods | join("/"))" else "no backend route" end) | `\(.source)` |")) end),
    (if (.js_no_route | length) > 0 then ("", "## Page JS calls to a URL no route matches (\(.js_no_route | length))\n", (.js_no_route[] | "- `\(.source)` \(.method // "?") `\(.url)` (\(.context))")) else empty end),
    (if (.js_unresolved | length) > 0 then ("", "## Page JS calls whose URL cannot be resolved (\(.js_unresolved | length))\n", "Dynamic or concatenated URLs; give the URL and pages in `_map/overrides.yaml` (path:, pages:).\n", (.js_unresolved[] | "- `\(.source)`: \(.reason)")) else empty end),
    "", "## Unresolved call sites (\(.unresolved | length))\n",
    (if (.unresolved | length) == 0 then "None." else (.unresolved[] | "- `\(.file):\(.line)`: \(.reason)") end),
    (if (.overrides_unused | length) > 0 then ("", "## Overrides that match nothing (\(.overrides_unused | length))\n", "Check the source in _map/overrides.yaml (file moved or line changed):\n", (.overrides_unused[] | "- `\(.)`")) else empty end)
  ' "$CD/api-links.json" > "$CD/api-links.md"
done

# ---- backend view: which routes nobody calls
CL_FILES=$(for C in $CLIENTS; do printf '%s ' "$DOCS/_map/$C/api-links.json"; done)
"$JQ" -n --slurpfile br "$BD/routes.json" --slurpfile mods "$TMPD/modules.json" --argjson links "$("$JQ" -s '[.[].links[] | select(.status == "matched") | .route]' $CL_FILES)" \
  --argjson per "$("$JQ" -s 'map({client, counts})' $CL_FILES)" '
  $mods[0] as $M |
  # one definition (file:line) = one route: Route::match([get, post]) counts as called if either is
  ([$br[0].routes[] | {key, d: "\(.file):\(.line)"}]) as $defs |
  ([$defs[] | select(.key as $k | $links | index($k)) | .d] | unique) as $calledDefs |
  ([$defs[] | select(.d as $d | $calledDefs | index($d)) | .key] + $links | unique) as $called |
  ([$br[0].routes[] | select(.shadowed | not) | .key] | unique) as $all |
  {backend: $br[0].repo, commit: $br[0].commit, clients: $per,
   routes: ($all | length), called: ([$all[] | select(. as $k | $called | index($k))] | length),
   modules: [$M.modules[] | {id, product, critical,
       external_callers: (.product != "nt" or .id == "external-api" or .id == "nt-jiva"),
       confirmed_unused: (.id == "receptionist" or .id == "research-dashboard"),
       routes: (.routes | length), called: ([.routes[] | select(. as $k | $called | index($k))] | length),
       not_called: [.routes[] | select(. as $k | $called | index($k) | not)]}],
   unassigned_not_called: [$M.unassigned_routes[] | select(. as $k | $called | index($k) | not)]}' > "$TMPD/backend.json" || die "backend summary failed"
"$JQ" -r '
  "# API links: who calls \(.backend)\n",
  "Built from \(.backend) `\(.commit)` by scripts/link-apis.sh.\n",
  (.clients[] | "- \(.client): \(.counts.calls) calls, \(.counts.matched) matched, \(.counts.method_mismatch + .counts.no_route) with no matching route, \(.counts.unresolved) unresolved"),
  "", "**\(.called) of \(.routes) backend routes are called by a screen in this workspace.**\n",
  "Modules marked *external callers* belong to other products or partner APIs whose clients are not in this workspace, so \"not called\" is expected there.\n",
  "| Module | Product | Routes | Called | Not called | Note |", "|---|---|---|---|---|---|",
  (.modules[] | "| \(.id) | \(.product) | \(.routes) | \(.called) | \(.not_called | length) | \(if .confirmed_unused then "confirmed not in use" elif .external_callers then "external callers" else "" end) |"),
  "", "## Routes no screen calls (NT modules, possibly unused)\n",
  (.modules[] | select((.external_callers | not) and (.confirmed_unused | not) and (.not_called | length) > 0) |
    "### \(.id) (\(.not_called | length))\n", (.not_called[] | "- `\(.)`"), "")
' "$TMPD/backend.json" > "$BD/api-links.md"

# ---- not-in-use.md block
if [ $UPD = 1 ]; then
  NIU="$DOCS/not-in-use.md"; [ -f "$NIU" ] || die "no not-in-use.md (run seed-docs.sh)"
  BLOCK=$("$JQ" -r '
    "<!-- link-apis:start -->", "### Backend routes no NT screen calls (from /atreya:link-apis)\n",
    "Needs confirmation: a route may still be used by a client outside this workspace.\n",
    (.modules[] | select((.external_callers | not) and (.confirmed_unused | not) and (.not_called | length) > 0) |
      "- **\(.id)** (\(.not_called | length) of \(.routes)): \(.not_called | map("`\(.)`") | join(", "))"),
    "<!-- link-apis:end -->"' "$TMPD/backend.json")
  if grep -q '<!-- link-apis:start -->' "$NIU"; then
    # the block goes through a file: macOS awk rejects newlines in -v values
    printf '%s\n' "$BLOCK" > "$TMPD/blk"
    awk -v bf="$TMPD/blk" '/<!-- link-apis:start -->/ { while ((getline l < bf) > 0) print l; close(bf); skip = 1; next } /<!-- link-apis:end -->/ { skip = 0; next } !skip' "$NIU" > "$TMPD/niu" && cp "$TMPD/niu" "$NIU"
  else
    printf '\n%s\n' "$BLOCK" >> "$NIU"
  fi
  echo "updated the link-apis block in $NIU"
fi

# ---- summary
"$JQ" -r '(.clients[] | "link-apis: \(.client): \(.counts.calls) calls → \(.counts.matched) matched (\(.counts.matched_with_page) with a page, \(.counts.matched_without_page) without), \(.counts.method_mismatch) method mismatch, \(.counts.no_route) no route, \(.counts.unresolved) unresolved; overrides \(.counts.overrides_applied) applied, \(.counts.overrides_unused) unused"),
  "link-apis: \(.backend): \(.called) of \(.routes) routes called by a screen in this workspace"' "$TMPD/backend.json"
if [ -n "$MOD" ]; then
  "$JQ" -r --arg m "$MOD" '.modules[] | select(.id == $m) | "module \(.id): \(.called) of \(.routes) backend routes called; not called: \(.not_called | length)"' "$TMPD/backend.json"
  for C in $CLIENTS; do
    "$JQ" -r --arg m "$MOD" --arg c "$C" '[.links[] | select(.module == $m or .caller_module == $m)] as $l |
      "module \($m) ← \($c): \($l | length) calls (\([$l[] | select(.status == "matched")] | length) matched, \([$l[] | select(.status != "matched")] | length) with no matching route)"' "$DOCS/_map/$C/api-links.json"
  done
fi
for C in $CLIENTS; do echo "wrote $DOCS/_map/$C/api-links.json and api-links.md"; done
echo "wrote $BD/api-links.md"
