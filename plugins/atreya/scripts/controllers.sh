#!/bin/bash
# controllers.sh [--root R] REPO
#
# Static parse of app/Http/Controllers/**/*.php: for every method, its line
# range and what it touches: views (view('x.y') / View::make), models (classes
# imported from App\Models used as X:: / new X), tables (DB::table('t') plus the
# models' tables from models.json). Writes _map/<REPO>/controllers.json.
# Guarded files (e.g. SamvitPaymentBridgeController.php) are listed by name
# only, never opened.
#
# Also (used by impact-facts.sh to trace indirect dependencies):
#   per method  uses         other App\ classes it uses (service, job, event, ...):
#                            imported and used as X:: / new X / a type-hinted
#                            parameter / $this->prop typed by such a class; or an
#                            unqualified class of the same namespace
#               writes       tables it writes: Model::create/update/... or a
#                            Model:: line with ->update/->delete/..., or
#                            DB::table('t')->insert/update/delete/..., or
#                            $var->save()/update()/delete() where $var was
#                            assigned from a model (new X / X::find...) or is a
#                            type-hinted model parameter; "?" = model unknown
#               transaction  the method opens a DB transaction
#   classes     the same per-method record for every other app/**/*.php class
#               (services, jobs, listeners, ...; not Controllers or Models)
#   events      event => listeners from EventServiceProvider's $listen array
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"; mkdir -p "$OUTD" || die "cannot create $OUTD"
FILES=$(tracked_files "$REPO" 'app/Http/Controllers/*.php')
[ -n "$FILES" ] || die "$NAME has no app/Http/Controllers"
OTHER=$(tracked_files "$REPO" 'app/*.php' | grep -v -e '^app/Http/Controllers/' -e '^app/Models/')
GUARDED=$(git -C "$REPO" ls-files 'app/*.php' | grep -v '^app/Models/' | grep -vxF -f <(printf '%s\n' "$FILES" "$OTHER"))

RAW=$(cd "$REPO" && printf '%s\n' "$FILES" "$OTHER" | grep . | tr '\n' '\0' | xargs -0 awk '
function mask(s,   i, c, q, o) { o = ""; q = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
    if (q != "") { if (c == "\\") { o = o "xx"; i++; continue } if (c == q) { q = ""; o = o c } else o = o "x"; continue }
    if (c == "\047" || c == "\"") q = c; o = o c }
  return o }
# resolve a class name written in code to its fully qualified name ("" = not an App class)
function fqof(n) { sub(/^\\/, "", n)
  if (n ~ /\\/) return (n ~ /^App\\/ ? n : "")
  if (n in oth) return oth[n]
  if (n in use) return ""
  return (ns ~ /^App(\\|$)/ ? "?" ns "\\" n : "") }
function uses(c, ln) { if (c != "") printf "U\t%s\t%s\t%s\t%d\n", fq, meth, c, ln }
function endm() { if (meth != "") printf "X\t%s\t%s\t%s\t%d\t%d\n", FILENAME, fq, meth, mstart, FNR; meth = "" }
FNR == 1 { if (meth != "") { printf "X\t%s\t%s\t%s\t%d\t%d\n", pf, fq, meth, mstart, pl } ns = ""; cls = ""; fq = ""; depth = 0; cdepth = -1; meth = ""; inblock = 0; inlisten = 0; ev = ""
  delete use; delete oth; delete ptype; delete prop }
{ pf = FILENAME; pl = FNR }
{ o = $0; m = mask(o)
  if (inblock) { i = index(m, "*/"); if (!i) next; o = substr(o, i + 2); m = substr(m, i + 2); inblock = 0 }
  i = index(m, "//"); if (i) { o = substr(o, 1, i - 1); m = substr(m, 1, i - 1) }
  i = index(m, "/*"); if (i) { j = index(substr(m, i + 2), "*/"); if (j) { o = substr(o, 1, i - 1) substr(o, i + j + 3); m = substr(m, 1, i - 1) substr(m, i + j + 3) } else { o = substr(o, 1, i - 1); m = substr(m, 1, i - 1); inblock = 1 } }
}
match(o, /^[ \t]*namespace[ \t]+[A-Za-z0-9_\\]+/) { ns = substr(o, RSTART, RLENGTH); sub(/.*namespace[ \t]+/, "", ns) }
match(o, /^[ \t]*use[ \t]+App\\[A-Za-z0-9_\\]+([ \t]+as[ \t]+[A-Za-z0-9_]+)?[ \t]*;/) {
  u = o; sub(/^[ \t]*use[ \t]+/, "", u); sub(/[ \t]*;.*/, "", u); a = u
  if (u ~ /[ \t]as[ \t]/) { sub(/[ \t]+as[ \t]+.*/, "", u); sub(/.*[ \t]as[ \t]+/, "", a) } else sub(/.*\\/, "", a)
  if (u ~ /^App\\Models\\/) use[a] = u; else oth[a] = u }
cls == "" && match(o, /^[ \t]*(abstract[ \t]+|final[ \t]+)?class[ \t]+[A-Za-z0-9_]+/) { cls = substr(o, RSTART, RLENGTH); sub(/.*class[ \t]+/, "", cls); fq = (ns == "" ? cls : ns "\\" cls); cdepth = depth
  printf "K\t%s\t%s\n", fq, FILENAME }
# EventServiceProvider: protected $listen = [ Event::class => [ Listener::class, ... ], ... ];
FILENAME ~ /EventServiceProvider\.php$/ && m ~ /\$listen[ \t]*=/ { inlisten = 1 }
inlisten { s = m; while (match(s, /\\?[A-Za-z][A-Za-z0-9_\\]*::class([ \t]*=>)?/)) { v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    isev = (v ~ /=>$/); sub(/::class.*/, "", v); c = fqof(v); sub(/^\?/, "", c); if (c == "") continue
    if (isev) ev = c; else if (ev != "") printf "E\t%s\t%s\t%s\t%d\n", ev, c, FILENAME, FNR }
  if (m ~ /\][ \t]*;/) inlisten = 0 }
# typed properties (also promoted constructor parameters): private OtpService $otp
cls != "" { s = m; while (match(s, /(private|protected|public)([ \t]+readonly)?[ \t]+\??\\?[A-Z][A-Za-z0-9_\\]*[ \t]+\$[A-Za-z0-9_]+/)) { v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    p = v; sub(/.*\$/, "", p); sub(/[ \t]+\$.*/, "", v); sub(/.*[ \t]\??/, "", v); c = fqof(v); if (c != "") prop[p] = c } }
cls != "" && meth == "" && match(o, /function[ \t]+[A-Za-z0-9_]+[ \t]*\(/) && depth == cdepth + 1 {
  meth = substr(o, RSTART, RLENGTH); sub(/^function[ \t]+/, "", meth); sub(/[ \t]*\($/, "", meth); mstart = FNR; mdepth = depth; delete ptype; delete vmod }
meth != "" {
  s = o; while (match(s, /(view|View::make|response\(\)->view)\([ \t]*["\047][A-Za-z0-9_.\/:-]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "V\t%s\t%s\t%s\n", fq, meth, v; s = substr(s, RSTART + RLENGTH) }
  s = o; while (match(s, /DB::table\([ \t]*["\047][A-Za-z0-9_]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "T\t%s\t%s\t%s\n", fq, meth, v; s = substr(s, RSTART + RLENGTH) }
  # a class name must start a token: "beginTransaction(" or "->Foo(" is not class Transaction / Foo
  s = m; pc = ""; wl = 0; while (match(s, /(new[ \t]+)?\\?[A-Z][A-Za-z0-9_]*(::|\()/)) { v = substr(s, RSTART, RLENGTH); pre = (RSTART > 1 ? substr(s, RSTART - 1, 1) : pc); pc = substr(s, RSTART + RLENGTH - 1, 1); rest = substr(s, RSTART + RLENGTH); s = rest
    if (v !~ /^\\/ && pre ~ /[A-Za-z0-9_$>:]/) continue
    st = (v ~ /::$/); sub(/^new[ \t]+/, "", v); sub(/^\\/, "", v); sub(/(::|\()$/, "", v)
    if (v in use) { printf "O\t%s\t%s\t%s\n", fq, meth, use[v]
      if (st && (rest ~ /^(create|forceCreate|insert|insertGetId|insertOrIgnore|update|updateOrCreate|updateOrInsert|firstOrCreate|upsert|destroy|increment|decrement|truncate)\(/ || rest ~ /->(update|delete|forceDelete|increment|decrement|save|insert|upsert)\(/)) { printf "W\t%s\t%s\tM:%s\t%d\n", fq, meth, use[v], FNR; wl = 1 } }
    else if (v != "DB" && v != cls) uses(fqof(v), FNR) }
  # type-hinted parameters: function x(Request $r, OtpService $svc)
  s = m; while (match(s, /[(,][ \t]*\??\\?[A-Z][A-Za-z0-9_\\]*[ \t]+\$[A-Za-z0-9_]+/)) { v = substr(s, RSTART + 1, RLENGTH - 1); s = substr(s, RSTART + RLENGTH)
    p = v; sub(/.*\$/, "", p); sub(/[ \t]+\$.*/, "", v); sub(/^[ \t]*\??/, "", v); if (v in use) { vmod[p] = use[v]; continue } c = fqof(v); if (c != "") { ptype[p] = c; uses(c, FNR) } }
  # $p = new Payment / $p = Payment::find(...): $p->save() then writes payments
  if (match(m, /\$[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*(new[ \t]+)?\\?[A-Z][A-Za-z0-9_]*(::|\()/)) { v = substr(m, RSTART, RLENGTH); p = v; sub(/^\$/, "", p); sub(/[ \t]*=.*/, "", p)
    c = v; sub(/^[^=]*=[ \t]*/, "", c); sub(/^new[ \t]+/, "", c); sub(/^\\/, "", c); sub(/(::|\()$/, "", c); if (c in use) vmod[p] = use[c]; else delete vmod[p] }
  # $this->prop = $svc (constructor assignment) and $this->prop->x() (use)
  if (match(m, /\$this->[A-Za-z0-9_]+[ \t]*=[ \t]*\$[A-Za-z0-9_]+[ \t]*;/)) { v = substr(m, RSTART, RLENGTH); p = v; sub(/^\$this->/, "", p); sub(/[ \t]*=.*/, "", p); sub(/.*=[ \t]*\$/, "", v); sub(/[ \t]*;$/, "", v); if (v in ptype) prop[p] = ptype[v] }
  s = m; while (match(s, /\$this->[A-Za-z0-9_]+->/)) { p = substr(s, RSTART + 7, RLENGTH - 9); s = substr(s, RSTART + RLENGTH); if (p in prop) uses(prop[p], FNR) }
  if (match(o, /DB::table\([ \t]*["\047][A-Za-z0-9_]+["\047]/) && m ~ /->(insert|insertGetId|insertOrIgnore|update|updateOrInsert|upsert|delete|increment|decrement|truncate)\(/) {
    s = o; while (match(s, /DB::table\([ \t]*["\047][A-Za-z0-9_]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "W\t%s\t%s\tT:%s\t%d\n", fq, meth, v, FNR; s = substr(s, RSTART + RLENGTH) }; wl = 1 }
  if (!wl && match(m, /\$[A-Za-z_][A-Za-z0-9_]*->(save|update|delete|forceDelete)\(/) && m !~ /\$this->(save|update|delete|forceDelete)\(/) {
    p = substr(m, RSTART + 1, RLENGTH - 1); sub(/->.*/, "", p)
    if (p in vmod) printf "W\t%s\t%s\tM:%s\t%d\n", fq, meth, vmod[p], FNR; else printf "W\t%s\t%s\t?\t%d\n", fq, meth, FNR }
  if (m ~ /DB::transaction\(|beginTransaction\(/) printf "R\t%s\t%s\n", fq, meth
}
{ t = m; op = gsub(/\{/, "{", t); cl = gsub(/\}/, "}", t); depth += op - cl
  if (meth != "" && depth <= mdepth && FNR > mstart) endm()
  if (meth != "" && depth <= mdepth && FNR == mstart && op > 0 && op == cl) endm() }
END { if (meth != "") printf "X\t%s\t%s\t%s\t%d\t%d\n", pf, fq, meth, mstart, pl }' 2>/dev/null)

MT='{}'; [ -f "$OUTD/models.json" ] && MT=$("$JQ" -c '[.models[] | {key: .fqcn, value: .table}] | from_entries' "$OUTD/models.json")
COMMIT=$(repo_stamp "$REPO")
JSON=$(printf '%s\n' "$RAW" | redact | "$JQ" -R -s --arg repo "$NAME" --arg commit "$COMMIT" --argjson mt "$MT" --arg guarded "$GUARDED" '
  split("\n") | map(select(length > 0) | split("\t")) as $rows |
  def pick($k; $c; $m): [$rows[] | select(.[0] == $k and .[1] == $c and .[2] == $m) | .[3]] | unique;
  ([$rows[] | select(.[0] == "K") | .[1]] | unique) as $known |
  def kindof: (split("\\") | if length > 2 then .[1] else "" end) as $s |
    {"Services": "service", "Service": "service", "Jobs": "job", "Events": "event", "Listeners": "listener", "Mail": "mail", "Facades": "facade", "Actions": "action",
     "Notifications": "notification", "Repositories": "repository", "Repository": "repository", "Helpers": "helper",
     "Observers": "observer", "Http": "http", "Providers": "provider", "Console": "console"}[$s] // "other";
  # an unqualified name of the same namespace ("?App\\X\\Y") counts only if that class exists
  def real: if startswith("?") then (.[1:] as $c | if ($known | index($c)) then $c else empty end) else . end;
  def method($x): {name: $x[3], lines: [($x[4] | tonumber), ($x[5] | tonumber)],
     views: pick("V"; $x[2]; $x[3]),
     models: pick("O"; $x[2]; $x[3]),
     tables: ((pick("T"; $x[2]; $x[3]) + [pick("O"; $x[2]; $x[3])[] | $mt[.] // empty]) | unique),
     uses: ([$rows[] | select(.[0] == "U" and .[1] == $x[2] and .[2] == $x[3]) | {class: (.[3] | real), line: (.[4] | tonumber)}]
            | map(select(.class != $x[2])) | group_by(.class) | map({class: .[0].class, kind: (.[0].class | kindof), lines: (map(.line) | unique)})),
     writes: ([$rows[] | select(.[0] == "W" and .[1] == $x[2] and .[2] == $x[3]) |
               (if .[3] == "?" then {table: "?", via: "unknown model"}
                elif (.[3] | startswith("T:")) then {table: .[3][2:], via: "DB::table"}
                else {table: ($mt[.[3][2:]] // "?"), via: "model \(.[3][2:] | split("\\") | last)"} end) + {line: (.[4] | tonumber)}]
              | group_by(.table + " " + .via) | map({table: .[0].table, via: .[0].via, lines: (map(.line) | unique)})),
     transaction: any($rows[]; .[0] == "R" and .[1] == $x[2] and .[2] == $x[3])};
  def classes($ctl): $rows | map(select(.[0] == "X" and ((.[1] | startswith("app/Http/Controllers/")) == $ctl))) | group_by(.[2]) | map({
      fqcn: .[0][2], file: .[0][1]} + (if $ctl then {} else {kind: (.[0][2] | kindof)} end) + {
      methods: (map(method(.)) | sort_by(.lines[0]))
    }) | sort_by(.fqcn);
  classes(true) as $ctl | classes(false) as $oth |
  {repo: $repo, commit: $commit,
   counts: {controllers: ($ctl | length), methods: ([$ctl[].methods[]] | length),
            methods_with_views: ([$ctl[].methods[] | select(.views | length > 0)] | length),
            classes: ($oth | length)},
   guarded_files: ($guarded | split("\n") | map(select(length > 0))),
   controllers: $ctl,
   classes: $oth,
   events: ([$rows[] | select(.[0] == "E")] | group_by(.[1]) | map({event: .[0][1],
             listeners: (map(.[2]) | unique), source: "\(.[0][3]):\(map(.[4] | tonumber) | min)"}))}') || die "could not build controllers.json"
printf '%s\n' "$JSON" > "$OUTD/controllers.json"
printf '%s' "$JSON" | "$JQ" -r '"controllers: \(.repo) @ \(.commit[0:10]): \(.counts.controllers) controllers, \(.counts.methods) methods (\(.counts.methods_with_views) render views), \(.guarded_files | length) guarded file(s) not opened"'
echo "wrote $OUTD/controllers.json"
