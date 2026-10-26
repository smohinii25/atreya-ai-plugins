#!/bin/bash
# routes.sh [--root R] REPO
#
# Static parse of a Laravel repo's routes/*.php (no PHP, no DB). Writes
#   <root>/atreya-docs/_map/<REPO>/routes.json   machine copy (deterministic)
#   <root>/atreya-docs/_map/<REPO>/routes.md     readable table
# Understands: Route::get/post/put/patch/delete/options/any/match/resource/
# apiResource/view/redirect, Route::group([...]), Route::middleware()/prefix()/
# controller()->group(), nested groups, closures, [X::class,'m'] and 'X@m'
# actions, ->middleware() and ->name(). URL prefix per file comes from
# app/Providers/RouteServiceProvider.php (Laravel default if absent).
# Lines it cannot understand are listed under "unparsed" with counts.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"
FILES=$(tracked_files "$REPO" 'routes/*.php' | grep -vE '^routes/(channels|console)\.php$')
[ -n "$FILES" ] || die "$NAME has no routes/*.php (not a Laravel repo?)"
mkdir -p "$OUTD" || die "cannot create $OUTD"

# ---- URL prefix per route file, from RouteServiceProvider
PROVIDER=app/Providers/RouteServiceProvider.php
PREFIXES=""
if tracked_files "$REPO" "$PROVIDER" | grep -qx "$PROVIDER"; then
  PREFIXES=$(awk '
    /^[ \t]*(\/\/|#|\*|\/\*)/ { next }          # comments may mention prefix(...) too
    { sub(/[ \t]\/\/.*/, ""); line = line " " $0 }
    /;/ { if (line ~ /Route::/ && match(line, /routes\/[A-Za-z0-9_.-]+\.php/)) {
            f = substr(line, RSTART, RLENGTH); p = ""
            if (match(line, /prefix\([ \t]*["\047][^"\047]*["\047]/)) { p = substr(line, RSTART, RLENGTH); sub(/^prefix\([ \t]*["\047]/, "", p); sub(/["\047]$/, "", p) }
            print f "\t" p
          }
          line = "" }' "$REPO/$PROVIDER")
fi
prefix_of() {  # prefix_of routes/x.php -> prefix<TAB>source
  local hit; hit=$(printf '%s\n' "$PREFIXES" | awk -F '\t' -v f="$1" '$1 == f { print $2 "\tRouteServiceProvider"; exit }')
  if [ -n "$hit" ]; then printf '%s\n' "$hit"; return; fi
  [ "$1" = routes/api.php ] && printf 'api\tLaravel default\n' || printf '\tLaravel default\n'
}

# ---- the parser (one route file at a time)
PARSER='
function mask(s,   i, c, q, o) {   # blank out string contents, keep length
  o = ""; q = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != "") { if (c == "\\") { o = o "xx"; i++; continue } if (c == q) { q = ""; o = o c } else o = o "x"; continue }
    if (c == "\047" || c == "\"") q = c
    o = o c
  }
  return o
}
function braces(m,   t, o, c) { t = m; o = gsub(/\{/, "{", t); c = gsub(/\}/, "}", t); depth += o - c
  while (gtop > 0 && depth < glevel[gtop]) gtop-- }
function q1(s, re,   v) {       # first quoted string matching re (re ends at the opening quote)
  if (!match(s, re)) return ""
  v = substr(s, RSTART + RLENGTH); sub(/["\047].*/, "", v); return v
}
function quoted_list(s,   out, v) { out = ""
  while (match(s, /["\047][^"\047]*["\047]/)) { v = substr(s, RSTART + 1, RLENGTH - 2); out = out (out == "" ? "" : ",") v; s = substr(s, RSTART + RLENGTH) }
  return out }
function mw_of(s,   v) {
  if (match(s, /["\047]middleware["\047][ \t]*=>[ \t]*(\[[^]]*\]|["\047][^"\047]*["\047])/)) return quoted_list(substr(s, RSTART + 12, RLENGTH - 12))
  if (match(s, /middleware\([ \t]*(\[[^]]*\]|["\047][^"\047]*["\047])/)) return quoted_list(substr(s, RSTART + 11, RLENGTH - 11))
  return "" }
function joinp(a, b) { if (a == "") return b; if (b == "") return a; return a "/" b }
function clean(u) { gsub(/\/+/, "/", u); sub(/^\//, "", u); sub(/\/$/, "", u); return u }
function gprefix(   i, p) { p = base; for (i = 1; i <= gtop; i++) p = joinp(p, gpre[i]); return p }
function gmw(   i, m) { m = ""; for (i = 1; i <= gtop; i++) if (gmid[i] != "") m = m (m == "" ? "" : ",") gmid[i]; return m }
function gctl(   i, c) { c = ""; for (i = 1; i <= gtop; i++) if (gc[i] != "") c = gc[i]; return c }
function emit(meth, uri, ctl, act, mw, nm, kind) {
  uri = clean(joinp(gprefix(), uri)); if (uri == "") uri = "/"
  printf "R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", toupper(meth), uri, ctl, act, mw, nm, FILE, sl, kind
}
function unparsed(s) { gsub(/[ \t]+/, " ", s); printf "U\t%s\t%d\t%s\n", FILE, sl, substr(s, 1, 140) }
function route(s, m,   verb, rest, meths, uri, ctl, act, mw, nm, n, i, arr, r) {
  if (!match(m, /(Route::|->)(get|post|put|patch|delete|options|any|match|resource|apiResource|view|redirect)\(/)) return 0
  verb = substr(s, RSTART, RLENGTH); sub(/^(Route::|->)/, "", verb); sub(/\($/, "", verb)
  rest = substr(s, RSTART + RLENGTH)
  mw = gmw(); r = mw_of(substr(s, 1, RSTART)); if (r != "") mw = mw (mw == "" ? "" : ",") r   # chained before the verb
  meths = verb
  if (verb == "match") { if (!match(rest, /^[ \t]*\[[^]]*\]/)) { unparsed(s); return 1 }
    a0 = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)   # save before quoted_list() moves RSTART
    meths = quoted_list(a0); sub(/^[ \t]*,/, "", rest) }
  if (verb == "any") meths = "any"
  if (!match(rest, /^[ \t]*["\047][^"\047]*["\047]/)) { unparsed(s); return 1 }
  uri = substr(rest, RSTART, RLENGTH); sub(/^[ \t]*["\047]/, "", uri); sub(/["\047]$/, "", uri)
  rest = substr(rest, RSTART + RLENGTH)
  ctl = ""; act = ""
  if (match(rest, /\[[ \t]*\\?[A-Za-z0-9_\\]+::class[ \t]*,[ \t]*["\047][A-Za-z0-9_]+["\047]/)) {
    act = substr(rest, RSTART, RLENGTH); ctl = act; sub(/^\[[ \t]*\\?/, "", ctl); sub(/::class.*/, "", ctl)
    sub(/.*,[ \t]*["\047]/, "", act); sub(/["\047]$/, "", act)
  } else if (match(rest, /^[ \t]*,[ \t]*["\047][A-Za-z0-9_\\]+@[A-Za-z0-9_]+["\047]/)) {
    act = substr(rest, RSTART, RLENGTH); sub(/^[ \t]*,[ \t]*["\047]/, "", act); sub(/["\047]$/, "", act)
    ctl = act; sub(/@.*/, "", ctl); sub(/.*@/, "", act)
  } else if (match(rest, /^[ \t]*,[ \t]*function/) || match(rest, /^[ \t]*,[ \t]*fn[ \t]*\(/)) { ctl = ""; act = "Closure"
  } else if (match(rest, /^[ \t]*,[ \t]*["\047][A-Za-z0-9_]+["\047]/) && gctl() != "" && verb != "view" && verb != "redirect") {
    act = substr(rest, RSTART, RLENGTH); sub(/^[ \t]*,[ \t]*["\047]/, "", act); sub(/["\047]$/, "", act); ctl = gctl()
  } else if (match(rest, /^[ \t]*,[ \t]*\\?[A-Za-z0-9_\\]+::class/)) {
    ctl = substr(rest, RSTART, RLENGTH); sub(/^[ \t]*,[ \t]*\\?/, "", ctl); sub(/::class$/, "", ctl); act = (verb ~ /resource/) ? "" : "__invoke"
  } else if (verb == "view" || verb == "redirect") { act = verb
  } else { unparsed(s); return 1 }
  r = mw_of(rest); if (r != "") mw = mw (mw == "" ? "" : ",") r
  nm = q1(rest, "->name\\([ \t]*[\"\047]")
  if (verb == "resource" || verb == "apiResource") {
    p = uri; sub(/.*\//, "", p); sub(/s$/, "", p); p = "{" p "}"
    emit("get", uri, ctl, "index", mw, nm, "resource")
    if (verb == "resource") emit("get", uri "/create", ctl, "create", mw, nm, "resource")
    emit("post", uri, ctl, "store", mw, nm, "resource"); emit("get", uri "/" p, ctl, "show", mw, nm, "resource")
    if (verb == "resource") emit("get", uri "/" p "/edit", ctl, "edit", mw, nm, "resource")
    emit("put", uri "/" p, ctl, "update", mw, nm, "resource"); emit("patch", uri "/" p, ctl, "update", mw, nm, "resource")
    emit("delete", uri "/" p, ctl, "destroy", mw, nm, "resource"); return 1
  }
  n = split(meths, arr, ",")
  for (i = 1; i <= n; i++) emit(arr[i], uri, ctl, act, mw, nm, (act == "Closure" ? "closure" : "route"))
  return 1
}
function statement(s, m, opener) {
  if (route(s, m)) return
  if (opener && m ~ /group\(/) {
    gtop++; glevel[gtop] = depth + 1
    # regexes are passed as strings: a /re/ literal argument would be matched against $0
    gpre[gtop] = q1(s, "[\"\047]prefix[\"\047][ \t]*=>[ \t]*[\"\047]"); if (gpre[gtop] == "") gpre[gtop] = q1(s, "prefix\\([ \t]*[\"\047]")
    gmid[gtop] = mw_of(s)
    gc[gtop] = ""; if (match(s, /controller\([ \t]*\\?[A-Za-z0-9_\\]+::class/)) { gc[gtop] = substr(s, RSTART, RLENGTH); sub(/^controller\([ \t]*\\?/, "", gc[gtop]); sub(/::class$/, "", gc[gtop]) }
    return
  }
  if (m ~ /Route::(pattern|bind|model|fallback|macro)/) return
  unparsed(s)
}
BEGIN { depth = 0; gtop = 0; inblock = 0; buf = "" }
{
  o = $0; m = mask(o)
  # strip comments (/* */ blocks, // and #), counting commented-out routes
  if (inblock) { i = index(m, "*/"); if (!i) { if (o ~ /Route::/) commented++; next } o = substr(o, i + 2); m = substr(m, i + 2); inblock = 0 }
  while (1) {
    i1 = index(m, "//"); i2 = index(m, "#"); i3 = index(m, "/*"); i = 0
    if (i1 && (!i || i1 < i)) i = i1; if (i2 && (!i || i2 < i)) i = i2; if (i3 && (!i || i3 < i)) i = i3
    if (!i) break
    if (i == i3) { e = index(substr(m, i + 2), "*/")
      if (e) { if (substr(o, i, e + 3) ~ /Route::/) commented++; o = substr(o, 1, i - 1) substr(o, i + e + 3); m = substr(m, 1, i - 1) substr(m, i + e + 3); continue }
      if (substr(o, i) ~ /Route::/) commented++; o = substr(o, 1, i - 1); m = substr(m, 1, i - 1); inblock = 1; break }
    if (substr(o, i) ~ /Route::/) commented++
    o = substr(o, 1, i - 1); m = substr(m, 1, i - 1); break
  }
  if (match(o, /^[ \t]*use[ \t]+[A-Za-z0-9_\\]+([ \t]+as[ \t]+[A-Za-z0-9_]+)?[ \t]*;/)) {
    u = o; sub(/^[ \t]*use[ \t]+/, "", u); sub(/[ \t]*;.*/, "", u); a = u
    if (u ~ /[ \t]as[ \t]/) { sub(/[ \t]+as[ \t]+.*/, "", u); sub(/.*[ \t]as[ \t]+/, "", a) } else { sub(/.*\\/, "", a) }
    printf "USE\t%s\t%s\n", a, u; next
  }
  while (1) {
    if (buf == "") {
      i = index(m, "Route::")
      if (!i) { braces(m); break }
      braces(substr(m, 1, i - 1)); buf = substr(o, i); bufm = substr(m, i); sl = NR; o = ""; m = ""
    } else if (o != "" || m != "") { buf = buf " " o; bufm = bufm " " m; o = ""; m = "" }
    ps = index(bufm, ";"); pb = 0
    if (match(bufm, /(function|fn)[ \t]*\([^)]*\)[ \t]*(use[ \t]*\([^)]*\)[ \t]*)?(:[ \t]*[A-Za-z\\]+[ \t]*)?\{/)) pb = RSTART + RLENGTH - 1
    if (!ps && !pb) break                                  # statement continues on next line
    if (pb && (!ps || pb < ps)) { p = pb; op = 1 } else { p = ps; op = 0 }
    st = substr(buf, 1, p); stm = substr(bufm, 1, p)
    o = substr(buf, p + 1); m = substr(bufm, p + 1); buf = ""; bufm = ""
    statement(st, stm, op)
    braces(stm)
    if (o == "" && m == "") break
  }
}
END { if (buf != "") { sl = sl; unparsed(buf) } printf "C\t%s\t%d\n", FILE, commented }'

RAW=""; FILESMETA=""
for f in $FILES; do
  pf=$(prefix_of "$f"); p=${pf%%	*}
  RAW="$RAW$(awk -v FILE="$f" -v base="$p" "$PARSER" "$REPO/$f")
"
  FILESMETA="${FILESMETA}F	$f	$p	${pf#*	}
"
done

# ---- controller FQCN + file (PSR-4 App\ -> app/), existence and guard flag
CTRLS=$(printf '%s\n' "$RAW" | awk -F '\t' '
  $1 == "USE" { use[$2] = $3; next }
  $1 == "R" && $4 != "" { c = $4
    if (c ~ /^App\\/) f = c; else if (c in use) f = use[c]; else if (c ~ /\\/) f = "App\\Http\\Controllers\\" c; else f = "App\\Http\\Controllers\\" c
    print $4 "\t" f }' | sort -u)
CTRLMAP=$(printf '%s\n' "$CTRLS" | while IFS='	' read -r short fq; do
  [ -n "$short" ] || continue
  path=$(printf '%s' "$fq" | sed 's#^App\\#app\\#; s#\\#/#g').php
  if [ -f "$REPO/$path" ]; then is_secret_name "$path" && st=guarded || st=found; else st=missing; fi
  printf '%s\t%s\t%s\t%s\n' "$short" "$fq" "$path" "$st"
done)

COMMIT=$(repo_stamp "$REPO")
JSON=$( { printf '%s' "$FILESMETA"; printf '%s\n' "$RAW"; printf '%s\n' "$CTRLMAP" | awk 'NF { print "M\t" $0 }'; } | redact | "$JQ" -R -s \
  --arg repo "$NAME" --arg commit "$COMMIT" '
  split("\n") | map(select(length > 0) | split("\t")) as $rows |
  ($rows | map(select(.[0] == "M")) | map({key: .[1], value: {fqcn: .[2], file: .[3], status: .[4]}}) | from_entries) as $ctl |
  ($rows | map(select(.[0] == "R")) | to_entries | map(.value as $r | {
      method: $r[1], uri: $r[2],
      key: ($r[1] + " " + $r[2]),
      controller: (if $r[3] == "" then null else ($ctl[$r[3]].fqcn // $r[3]) end),
      action: (if $r[4] == "" then null else $r[4] end),
      controller_file: (if $r[3] == "" then null else ($ctl[$r[3]].file // null) end),
      controller_status: (if $r[3] == "" then null else ($ctl[$r[3]].status // "missing") end),
      middleware: (if $r[5] == "" then [] else ($r[5] | split(",")) end),
      name: (if $r[6] == "" then null else $r[6] end),
      file: $r[7], line: ($r[8] | tonumber), kind: $r[9], order: .key })) as $routes |
  ($routes | group_by(.key) | map(sort_by(.order) | (.[:-1] | map(.order)) ) | add // []) as $shadow |
  {
    repo: $repo, commit: $commit,
    route_files: ($rows | map(select(.[0] == "F")) | map({file: .[1], prefix: .[2], prefix_source: .[3]})),
    counts: {
      routes: ($routes | length),
      unique_routes: ($routes | map(.key) | unique | length),
      closures: ($routes | map(select(.kind == "closure")) | length),
      shadowed: ($shadow | length),
      unparsed: ($rows | map(select(.[0] == "U")) | length),
      commented_out_lines: ($rows | map(select(.[0] == "C") | (.[2] | tonumber)) | add // 0),
      controllers_missing: ($ctl | to_entries | map(select(.value.status == "missing")) | length),
      controllers_guarded: ($ctl | to_entries | map(select(.value.status == "guarded")) | length)
    },
    routes: ($routes | map(. + {shadowed: (.order as $o | $shadow | index($o) != null)} | del(.order)) | sort_by(.uri, .method, .file, .line)),
    unparsed: ($rows | map(select(.[0] == "U")) | map({file: .[1], line: (.[2] | tonumber), text: .[3]}))
  }') || die "could not build routes.json"
printf '%s\n' "$JSON" > "$OUTD/routes.json"

printf '%s' "$JSON" | "$JQ" -r '
  "# Routes: \(.repo)\n",
  "Built from commit `\(.commit)` by scripts/routes.sh (static parse, no PHP).\n",
  "| Route file | URL prefix | Prefix from |", "|---|---|---|",
  (.route_files[] | "| `\(.file)` | `\(.prefix)` | \(.prefix_source) |"), "",
  "**\(.counts.routes) routes** (\(.counts.unique_routes) unique), \(.counts.closures) closures, \(.counts.shadowed) shadowed duplicates, \(.counts.unparsed) unparsed lines, \(.counts.commented_out_lines) commented-out route lines, \(.counts.controllers_missing) controller files not found, \(.counts.controllers_guarded) guarded.\n",
  "| Method | URI | Controller@action | Middleware | Name | Source |", "|---|---|---|---|---|---|",
  (.routes[] | "| \(.method) | `\(.uri)` | \(if .controller then ((.controller | split("\\") | last) + "@" + (.action // "")) else (.action // "") end)\(if .controller_status == "guarded" then " (guarded)" else "" end)\(if .shadowed then " **shadowed**" else "" end) | \(.middleware | join(", ")) | \(.name // "") | `\(.file):\(.line)` |"),
  "", "## Unparsed", "",
  (if (.unparsed | length) == 0 then "None." else (.unparsed[] | "- `\(.file):\(.line)` \(.text)") end)
' > "$OUTD/routes.md"

printf '%s' "$JSON" | "$JQ" -r '"routes: \(.repo) @ \(.commit[0:10]): \(.counts.routes) routes (\(.counts.unique_routes) unique), \(.counts.unparsed) unparsed, \(.counts.shadowed) shadowed, \(.counts.closures) closures, \(.counts.commented_out_lines) commented-out lines, controllers missing \(.counts.controllers_missing), guarded \(.counts.controllers_guarded)"'
echo "wrote $OUTD/routes.json and routes.md"
