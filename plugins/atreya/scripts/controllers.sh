#!/bin/bash
# controllers.sh [--root R] REPO
#
# Static parse of app/Http/Controllers/**/*.php: for every method, its line
# range and what it touches: views (view('x.y') / View::make), models (classes
# imported from App\Models used as X:: / new X), tables (DB::table('t') plus the
# models' tables from models.json). Writes _map/<REPO>/controllers.json.
# Guarded files (e.g. SamvitPaymentBridgeController.php) are listed by name
# only, never opened.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"; mkdir -p "$OUTD" || die "cannot create $OUTD"
FILES=$(tracked_files "$REPO" 'app/Http/Controllers/*.php')
[ -n "$FILES" ] || die "$NAME has no app/Http/Controllers"
GUARDED=$(git -C "$REPO" ls-files 'app/Http/Controllers/*.php' | grep -vxF -f <(printf '%s\n' "$FILES"))

RAW=$(cd "$REPO" && printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 awk '
function mask(s,   i, c, q, o) { o = ""; q = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
    if (q != "") { if (c == "\\") { o = o "xx"; i++; continue } if (c == q) { q = ""; o = o c } else o = o "x"; continue }
    if (c == "\047" || c == "\"") q = c; o = o c }
  return o }
function endm() { if (meth != "") printf "X\t%s\t%s\t%s\t%d\t%d\n", FILENAME, fq, meth, mstart, FNR; meth = "" }
FNR == 1 { if (meth != "") { printf "X\t%s\t%s\t%s\t%d\t%d\n", pf, fq, meth, mstart, pl } ns = ""; cls = ""; fq = ""; depth = 0; cdepth = -1; meth = ""; inblock = 0; delete use }
{ pf = FILENAME; pl = FNR }
{ o = $0; m = mask(o)
  if (inblock) { i = index(m, "*/"); if (!i) next; o = substr(o, i + 2); m = substr(m, i + 2); inblock = 0 }
  i = index(m, "//"); if (i) { o = substr(o, 1, i - 1); m = substr(m, 1, i - 1) }
  i = index(m, "/*"); if (i) { j = index(substr(m, i + 2), "*/"); if (j) { o = substr(o, 1, i - 1) substr(o, i + j + 3); m = substr(m, 1, i - 1) substr(m, i + j + 3) } else { o = substr(o, 1, i - 1); m = substr(m, 1, i - 1); inblock = 1 } }
}
match(o, /^[ \t]*namespace[ \t]+[A-Za-z0-9_\\]+/) { ns = substr(o, RSTART, RLENGTH); sub(/.*namespace[ \t]+/, "", ns) }
match(o, /^[ \t]*use[ \t]+App\\Models\\[A-Za-z0-9_\\]+([ \t]+as[ \t]+[A-Za-z0-9_]+)?[ \t]*;/) {
  u = o; sub(/^[ \t]*use[ \t]+/, "", u); sub(/[ \t]*;.*/, "", u); a = u
  if (u ~ /[ \t]as[ \t]/) { sub(/[ \t]+as[ \t]+.*/, "", u); sub(/.*[ \t]as[ \t]+/, "", a) } else sub(/.*\\/, "", a)
  use[a] = u }
cls == "" && match(o, /^[ \t]*(abstract[ \t]+|final[ \t]+)?class[ \t]+[A-Za-z0-9_]+/) { cls = substr(o, RSTART, RLENGTH); sub(/.*class[ \t]+/, "", cls); fq = (ns == "" ? cls : ns "\\" cls); cdepth = depth }
cls != "" && meth == "" && match(o, /function[ \t]+[A-Za-z0-9_]+[ \t]*\(/) && depth == cdepth + 1 {
  meth = substr(o, RSTART, RLENGTH); sub(/^function[ \t]+/, "", meth); sub(/[ \t]*\($/, "", meth); mstart = FNR; mdepth = depth }
meth != "" {
  s = o; while (match(s, /(view|View::make|response\(\)->view)\([ \t]*["\047][A-Za-z0-9_.\/:-]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "V\t%s\t%s\t%s\n", fq, meth, v; s = substr(s, RSTART + RLENGTH) }
  s = o; while (match(s, /DB::table\([ \t]*["\047][A-Za-z0-9_]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "T\t%s\t%s\t%s\n", fq, meth, v; s = substr(s, RSTART + RLENGTH) }
  s = m; while (match(s, /(new[ \t]+)?\\?[A-Z][A-Za-z0-9_]*(::|\()/)) { v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/^new[ \t]+/, "", v); sub(/^\\/, "", v); sub(/(::|\()$/, "", v); if (v in use) printf "O\t%s\t%s\t%s\n", fq, meth, use[v] }
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
  ($rows | map(select(.[0] == "X")) | group_by(.[2]) | map({
      fqcn: .[0][2], file: .[0][1],
      methods: (map(. as $x | {name: $x[3], lines: [($x[4] | tonumber), ($x[5] | tonumber)],
                 views: pick("V"; $x[2]; $x[3]),
                 models: pick("O"; $x[2]; $x[3]),
                 tables: ((pick("T"; $x[2]; $x[3]) + [pick("O"; $x[2]; $x[3])[] | $mt[.] // empty]) | unique)})
                | sort_by(.lines[0]))
    }) | sort_by(.fqcn)) as $ctl |
  {repo: $repo, commit: $commit,
   counts: {controllers: ($ctl | length), methods: ([$ctl[].methods[]] | length),
            methods_with_views: ([$ctl[].methods[] | select(.views | length > 0)] | length)},
   guarded_files: ($guarded | split("\n") | map(select(length > 0))),
   controllers: $ctl}') || die "could not build controllers.json"
printf '%s\n' "$JSON" > "$OUTD/controllers.json"
printf '%s' "$JSON" | "$JQ" -r '"controllers: \(.repo) @ \(.commit[0:10]): \(.counts.controllers) controllers, \(.counts.methods) methods (\(.counts.methods_with_views) render views), \(.guarded_files | length) guarded file(s) not opened"'
echo "wrote $OUTD/controllers.json"
