#!/bin/bash
# calls.sh [--root R] REPO
#
# Every backend API call a client repo makes, as METHOD + path (dynamic parts
# become {}, query strings dropped). Writes _map/<REPO>/calls.json.
#  Laravel client (Frontend): variables assigned config('app.backend_url') used as
#    ->get/post/put/patch/delete("$var/path"), ("{$var}/path"), ($var . '/path'),
#    or through a URL variable built that way; context = controller@method.
#  Flutter client (App): StringsConst getters "${AppEnvironment.baseUrl}/path" used
#    as url: StringsConst().name (+ method: MethodType.x within the call), and
#    direct "${AppEnvironment.baseUrl}/path" strings (links, method GET). Context =
#    enclosing Dart method -> files that call it -> their feature folders.
# Guarded files are never opened. Calls whose URL cannot be resolved statically
# are listed as "unresolved" with file:line.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"; mkdir -p "$OUTD" || die "cannot create $OUTD"
COMMIT=$(repo_stamp "$REPO")

if [ -n "$(tracked_files "$REPO" 'app/Http/Controllers/*.php')" ]; then
  KIND=laravel
  [ -f "$OUTD/controllers.json" ] || die "run controllers.sh $NAME first"
  FILES=$(tracked_files "$REPO" 'app/*.php')
  # C<TAB>file<TAB>line<TAB>METHOD<TAB>path<TAB>form     U<TAB>file<TAB>line<TAB>reason
  RAW=$(cd "$REPO" && printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 awk '
    function norm(p) { sub(/\?.*/, "", p); gsub(/\{?\$[A-Za-z_][A-Za-z0-9_]*(->[A-Za-z_]+|\[[^]]*\])*\}?/, "{}", p); gsub(/\/+/, "/", p); return p }
    # "/patient/" . $id -> /patient/{} ;  "/report?user_id=" . $id -> /report (query)
    function dyn(p, tail) { return (p !~ /\?/ && p ~ /\/$/ && tail ~ /^[ \t]*\./) ? p "{}" : p }
    # every backend URL string on a line, as a GET link; jq keeps it only if no
    # HTTP call in the same file uses that path (report pages, redirects, iframes)
    function scanlinks(s,   b, t, p, tail) {
      for (b in base) {
        t = s
        while (match(t, "\"\\{?\\$" b "\\}?/[^\"]*\"")) { p = substr(t, RSTART, RLENGTH); sub("^\"\\{?\\$" b "\\}?", "", p); sub(/"$/, "", p); printf "L\t%s\t%d\t?\t%s\tlink\n", FILENAME, FNR, norm(p); t = substr(t, RSTART + RLENGTH) }
        t = s
        while (match(t, "\\$" b "[ \t]*\\.[ \t]*[\"\047]/[^\"\047]*[\"\047]")) { p = substr(t, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", p); sub(/["\047]$/, "", p); tail = substr(t, RSTART + RLENGTH); printf "L\t%s\t%d\t?\t%s\tlink\n", FILENAME, FNR, norm(dyn(p, tail)); t = substr(t, RSTART + RLENGTH) }
      } }
    FNR == 1 { delete base; delete urlv }
    /^[ \t]*(\/\/|\*|#)/ { next }
    # $x = config(...backend_url...)
    match($0, /\$[A-Za-z_][A-Za-z0-9_]*[ \t]*=[^;]*config\([ \t]*["\047]app\.backend_url["\047]/) {
      v = substr($0, RSTART + 1); sub(/[ \t]*=.*/, "", v); base[v] = 1 }
    # $u = "$base/path" | $base . "/path"
    match($0, /\$[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*/) {
      v = substr($0, RSTART + 1, RLENGTH - 1); sub(/[ \t]*=.*/, "", v); rest = substr($0, RSTART + RLENGTH)
      for (b in base) {
        if (match(rest, "^[\"]\\{?\\$" b "\\}?(/[^\"]*)\"")) { p = substr(rest, RSTART, RLENGTH); sub("^[\"]\\{?\\$" b "\\}?", "", p); sub(/"$/, "", p); urlv[v] = norm(p) }
        else if (match(rest, "^\\$" b "[ \t]*\\.[ \t]*[\"\047]/[^\"\047]*[\"\047]")) { p = substr(rest, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", p); sub(/["\047]$/, "", p); tail = substr(rest, RSTART + RLENGTH); urlv[v] = norm(dyn(p, tail)) }
      } }
    { scanlinks($0) }
    match($0, /->(get|post|put|patch|delete)\([ \t]*/) {
      m = toupper(substr($0, RSTART + 2, RLENGTH - 2)); sub(/\(.*/, "", m)
      a = substr($0, RSTART + RLENGTH); done = 0
      for (b in base) {
        if (match(a, "^[\"]\\{?\\$" b "\\}?(/[^\"]*)\"")) { p = substr(a, RSTART, RLENGTH); sub("^[\"]\\{?\\$" b "\\}?", "", p); sub(/"$/, "", p); printf "C\t%s\t%d\t%s\t%s\tinterp\n", FILENAME, FNR, m, norm(p); done = 1; break }
        if (match(a, "^\\$" b "[ \t]*\\.[ \t]*[\"\047]/[^\"\047]*[\"\047]")) { p = substr(a, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", p); sub(/["\047]$/, "", p); tail = substr(a, RSTART + RLENGTH); printf "C\t%s\t%d\t%s\t%s\tconcat\n", FILENAME, FNR, m, norm(dyn(p, tail)); done = 1; break }
        if (match(a, "^config\\([ \t]*[\"\047]app\\.backend_url[\"\047][ \t]*\\)[ \t]*\\.[ \t]*[\"\047]/[^\"\047]*[\"\047]")) { p = substr(a, RSTART, RLENGTH); sub(/.*\.[ \t]*["\047]/, "", p); sub(/["\047]$/, "", p); printf "C\t%s\t%d\t%s\t%s\tconfig\n", FILENAME, FNR, m, norm(p); done = 1; break }
      }
      if (!done && match(a, /^config\([ \t]*["\047]app\.backend_url["\047][ \t]*\)[ \t]*\.[ \t]*["\047]\/[^"\047]*["\047]/)) { p = substr(a, RSTART, RLENGTH); sub(/.*\.[ \t]*["\047]/, "", p); sub(/["\047]$/, "", p); printf "C\t%s\t%d\t%s\t%s\tconfig\n", FILENAME, FNR, m, norm(p); done = 1 }
      if (!done && match(a, /^\$[A-Za-z_][A-Za-z0-9_]*[ \t]*[,)]/)) { v = substr(a, 2); sub(/[ \t]*[,)].*/, "", v); if (v in urlv) { printf "C\t%s\t%d\t%s\t%s\tvar\n", FILENAME, FNR, m, urlv[v]; done = 1 } }
      if (!done && (length(base) > 0 || a ~ /backend_url/)) printf "U\t%s\t%d\t%s call with a URL that is not a backend_url literal\n", FILENAME, FNR, m
    }' 2>/dev/null)
  CTX=$("$JQ" -c '[.controllers[] | .fqcn as $c | .file as $f | .methods[] | {file: $f, from: .lines[0], to: .lines[1], controller: $c, action: .name}]' "$OUTD/controllers.json")
elif [ -n "$(tracked_files "$REPO" 'lib/*.dart')" ]; then
  KIND=flutter
  FILES=$(tracked_files "$REPO" 'lib/*.dart')
  SC=$(printf '%s\n' "$FILES" | grep -E '(^|/)strings_const\.dart$' | head -n 1)
  # K<TAB>name<TAB>path   (StringsConst getters pointing at the backend)
  KONST=""
  [ -n "$SC" ] && KONST=$(awk '
    /^[ \t]*\/\// { next }
    match($0, /(final[ \t]+String|String[ \t]+get)[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(=>|=)[ \t]*["\047]\$\{AppEnvironment\.baseUrl\}\/[^"\047]*["\047]/) {
      s = substr($0, RSTART, RLENGTH); n = s; sub(/^(final[ \t]+String|String[ \t]+get)[ \t]+/, "", n); sub(/[ \t]*(=>|=).*/, "", n)
      p = s; sub(/.*\$\{AppEnvironment\.baseUrl\}/, "", p); sub(/["\047]$/, "", p); sub(/\?.*/, "", p)
      gsub(/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*/, "{}", p); printf "K\t%s\t%s\n", n, p }' "$REPO/$SC")
  # C<TAB>file<TAB>line<TAB>METHOD<TAB>path<TAB>form<TAB>dartMethod   U<TAB>file<TAB>line<TAB>reason
  RAW=$( { printf '%s\n' "$KONST"; cd "$REPO" && printf '%s\n' "$FILES" | grep -vxF "$SC" | tr '\n' '\0' | xargs -0 awk '
    FNR == 1 && FILENAME != prevf { flushpend(); prevf = FILENAME; dm = "" }
    NR == FNR && 0 { }
    function flushpend() { if (pend != "") { printf "C\t%s\t%d\t%s\t%s\tconst\t%s\n", pf, pl, (pm == "" ? "?" : pm), pend, pdm; pend = "" } }
    /^[ \t]*\/\// { next }
    match($0, /^[ \t]*(static[ \t]+)?(Future|Stream|void|dynamic|[A-Z][A-Za-z0-9_<>?, ]*)[ \t]+[a-z_][A-Za-z0-9_]*[ \t]*\(/) && $0 !~ /=/ {
      d = substr($0, RSTART, RLENGTH); sub(/[ \t]*\($/, "", d); sub(/.*[ \t]/, "", d); dm = d }
    pend != "" && (FNR - pl) > 8 { flushpend() }
    pend != "" && match($0, /MethodType\.[a-z]+/) { pm = toupper(substr($0, RSTART + 11, RLENGTH - 11)); flushpend() }
    match($0, /StringsConst\(\)\.[A-Za-z_][A-Za-z0-9_]*/) {
      flushpend(); n = substr($0, RSTART + 15, RLENGTH - 15); suf = substr($0, RSTART + RLENGTH)
      extra = (suf ~ /^\}?\/\$/ || suf ~ /^[ \t]*\+/) ? "/{}" : ""
      pend = "@" n extra; pf = FILENAME; pl = FNR; pm = ""; pdm = dm
      if (match($0, /MethodType\.[a-z]+/)) { pm = toupper(substr($0, RSTART + 11, RLENGTH - 11)); flushpend() } }
    match($0, /["\047]\$\{AppEnvironment\.baseUrl\}\/[^"\047$]*/) {
      p = substr($0, RSTART, RLENGTH); sub(/^["\047]\$\{AppEnvironment\.baseUrl\}/, "", p); sub(/\?.*/, "", p)
      if (p == "/" || p == "") printf "U\t%s\t%d\tbaseUrl joined with a dynamic endpoint\n", FILENAME, FNR
      else printf "C\t%s\t%d\tGET\t%s\tlink\t%s\n", FILENAME, FNR, p, dm }
    match($0, /url:[ \t]*[a-z][A-Za-z0-9_]*[ \t]*,/) && $0 !~ /StringsConst/ { printf "U\t%s\t%d\turl passed in a variable\n", FILENAME, FNR }
    END { flushpend() }' 2>/dev/null; } )
  # ---- who triggers each call: repository method -> the method that calls it
  # (T rows, with its enclosing method) -> the bloc event it handles or the
  # method itself -> the files that send that event / call that method (S rows)
  # -> ... until a screen. A class used by exactly one screen counts as that
  # screen; anything else stays "unresolved" (never credited to every screen).
  SCREENF=$(cd "$REPO" && printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 grep -lE 'class [A-Z][A-Za-z0-9_]*(Screen|Page)[ \t]+extends' 2>/dev/null)
  NONAPI=$(printf '%s\n' "$FILES" | grep -v '/api_services/')
  METHODS=$(printf '%s\n' "$RAW" | awk -F '\t' '$1 == "C" && $7 != "" { print $7 }' | sort -u | paste -sd'|' -)
  CTXROWS=""
  [ -n "$METHODS" ] && CTXROWS=$(cd "$REPO" && printf '%s\n' "$NONAPI" | tr '\n' '\0' | xargs -0 awk -v mode=ctx -v calls="$METHODS" -f "$ATREYA_LIB/dartctx.awk" 2>/dev/null)
  # a class a GoRoute builds is a screen even if it is not named *Screen/*Page
  # (Q rows: screen file -> screen id, as in screens.json)
  QROWS=""
  if [ -f "$OUTD/screens.json" ]; then
    QROWS=$("$JQ" -r '.screens[] | select(.file != null) | "Q\t\(.file)\t\(.id)"' "$OUTD/screens.json")
    RCLS=$("$JQ" -r '.go_routes[].class // empty' "$OUTD/screens.json" | sort -u)
    # GoRoutes whose screen class has no Screen/Page name: the last project widget
    # the route builds (child: AddMedicinePrescription()), not blocs/events/states
    RTF=$("$JQ" -r '.router // empty' "$OUTD/screens.json")
    if [ -n "$RTF" ] && [ -f "$REPO/$RTF" ]; then
      PCLS=$(printf '%s\n' "$CTXROWS" | awk -F '\t' '$1 == "D" { print $3 }' | grep -v -E '(Bloc|Cubit|Event|State|Repository|Service|Provider|Model|Response|Request)$' | sort -u)
      NULLR=$("$JQ" -r '[.go_routes[].line] | sort | .[]' "$OUTD/screens.json" | paste -sd' ' -)
      RFIX=$(awk -v lines="$NULLR" 'NR == FNR { ok[$0] = 1; next }
        FNR == 1 { n = split(lines, L, " ") }
        { for (i = n; i >= 1; i--) if (FNR >= L[i] + 0) { r = L[i]; break }
          if (i < 1) next
          t = $0; while (match(t, /[A-Z][A-Za-z0-9_]*\(/)) { c = substr(t, RSTART, RLENGTH - 1); if (c in ok) last[r] = c; t = substr(t, RSTART + RLENGTH) } }
        END { for (r in last) print r "\t" last[r] }' <(printf '%s\n' "$PCLS") "$REPO/$RTF")
      # only for routes screens.sh left without a class
      RFIX=$("$JQ" -r --arg fix "$RFIX" '([$fix | split("\n")[] | select(. != "") | split("\t") | {key: .[0], value: .[1]}] | from_entries) as $f |
        .go_routes[] | select(.class == null and $f[(.line | tostring)] != null) | "\(.line)\t\($f[(.line | tostring)])"' "$OUTD/screens.json")
      RCLS=$(printf '%s\n%s\n' "$RCLS" "$(printf '%s\n' "$RFIX" | cut -f2)" | grep . | sort -u)
    fi
    QROWS=$(printf '%s\n%s\n' "$QROWS" "$(printf '%s\n' "$CTXROWS" | awk -F '\t' 'NR == FNR { r[$0] = 1; next } $1 == "D" && ($3 in r) { print "Q\t" $2 "\t" $3 }' <(printf '%s\n' "$RCLS") -)" | grep . | sort -u)
    SCREENF=$(printf '%s\n%s\n' "$SCREENF" "$(printf '%s\n' "$QROWS" | cut -f2)" | grep . | sort -u)
  fi
  EVENTS=$(printf '%s\n' "$CTXROWS" | awk -F '\t' '$1 == "R" { print $3 }' | sort -u | paste -sd'|' -)
  # senders, up to 4 rounds: each round adds the enclosing methods of the last senders
  SEND=""; MS=$(printf '%s\n' "$CTXROWS" | awk -F '\t' '$1 == "T" && $5 != "" && $5 !~ /^@/ && $5 != "build" { print $5 }' | sort -u); DONE=""
  for round in 1 2 3 4; do
    NEW=$(printf '%s\n' "$MS" | grep -v -x -F -f <(printf '%s\n' "$DONE" | grep . || echo '#none#') | grep .)
    [ -n "$NEW" ] || [ "$round" = 1 ] || break
    DONE=$(printf '%s\n%s\n' "$DONE" "$NEW" | grep . | sort -u)
    S1=$(cd "$REPO" && printf '%s\n' "$NONAPI" | tr '\n' '\0' | xargs -0 awk -v mode=send -v events="$([ "$round" = 1 ] && printf '%s' "$EVENTS")" -v meths="$(printf '%s\n' "$NEW" | grep . | paste -sd'|' -)" -f "$ATREYA_LIB/dartctx.awk" 2>/dev/null)
    SEND=$(printf '%s\n%s\n' "$SEND" "$S1" | grep .)
    MS=$(printf '%s\n' "$S1" | awk -F '\t' '$6 != "" && $6 !~ /^@/ && $6 != "build" { print $6 }' | sort -u)
  done
  # classes of the non-screen files met on the way -> screens / files that use them
  INVOLVED=$(printf '%s\n%s\n' "$CTXROWS" "$SEND" | awk -F '\t' '$1 == "T" || $1 == "S" { print $2 }' | sort -u | grep -v -x -F -f <(printf '%s\n' "$SCREENF" | grep . || echo '#none#'))
  # files that name a class defined in an involved file (one grep pass per level;
  # 3 levels follow a widget inside a widget inside a screen)
  USES=""; LEVEL="$INVOLVED"; SEEN="$INVOLVED"
  ROUTERF=$([ -f "$OUTD/screens.json" ] && "$JQ" -r '.router // empty' "$OUTD/screens.json")
  for lvl in 1 2 3; do
    CLSDEF=$(printf '%s\n' "$CTXROWS" | awk -F '\t' 'NR == FNR { inv[$0] = 1; next } $1 == "D" && ($2 in inv) { print $3 "\t" $2 }' <(printf '%s\n' "$LEVEL" | grep . || echo '#none#') - | sort -u)
    [ -n "$CLSDEF" ] || break
    U1=$(cd "$REPO" && printf '%s\n' "$NONAPI" | grep -vxF "${ROUTERF:-#none#}" | tr '\n' '\0' | xargs -0 grep -o -w -H -F -f <(printf '%s\n' "$CLSDEF" | cut -f1 | sort -u) 2>/dev/null |
      awk -F'\t' -v scr="$(printf '%s\n' "$SCREENF" | paste -sd'|' -)" '
        NR == FNR { def[$1] = def[$1] "\t" $2; next }
        FNR == 1 && !started { started = 1; n = split(scr, a, "|"); for (i = 1; i <= n; i++) isscr[a[i]] = 1 }
        { i = index($0, ":"); uf = substr($0, 1, i - 1); c = substr($0, i + 1)
          m = split(substr(def[c], 2), dfs, "\t")
          for (j = 1; j <= m; j++) if (dfs[j] != uf) { print "F\t" dfs[j] "\t" uf; if (uf in isscr) print "W\t" dfs[j] "\t" uf } }' <(printf '%s\n' "$CLSDEF") - | sort -u)
    USES=$(printf '%s\n%s\n' "$USES" "$U1" | grep . | sort -u)
    LEVEL=$(printf '%s\n' "$U1" | awk -F '\t' '$1 == "F" { print $3 }' | sort -u | grep -v -x -F -f <(printf '%s\n%s\n' "$SEEN" "$SCREENF" | grep . || echo '#none#'))
    SEEN=$(printf '%s\n%s\n' "$SEEN" "$LEVEL" | grep . | sort -u)
  done
  # events sent while a GoRoute builds its screen belong to that screen
  GROWS=""
  [ -n "$ROUTERF" ] && GROWS=$("$JQ" -r '([.screens[] | {key: .id, value: .file}] | from_entries) as $f | .go_routes[] | select(.class != null and $f[.class] != null) | "G\t\(.line)\t\($f[.class])"' "$OUTD/screens.json") || die "could not read the GoRoutes of screens.json"
  [ -n "${RFIX:-}" ] && GROWS=$(printf '%s\n%s\n' "$GROWS" "$(printf '%s\n' "$CTXROWS" | awk -F '\t' 'NR == FNR { cls[$2] = cls[$2] " " $1; next } $1 == "D" && ($3 in cls) { n = split(cls[$3], l, " "); for (i = 1; i <= n; i++) print "G\t" l[i] "\t" $2 }' <(printf '%s\n' "$RFIX") -)" | grep . | sort -u)
  RAW="$RAW
$CTXROWS
$SEND
$USES
$GROWS
$QROWS
$([ -n "$ROUTERF" ] && printf 'Y\t%s\n' "$ROUTERF")
$(printf '%s\n' "$SCREENF" | grep . | sed 's#^#Z	#')"
  CTX='[]'
else
  die "$NAME is neither a Laravel nor a Flutter repo"
fi

JSON=$(printf '%s\n' "$RAW" | redact | "$JQ" -R -s --arg repo "$NAME" --arg commit "$COMMIT" --arg kind "$KIND" --argjson ctx "$CTX" '
  # feature folder of a Dart file: path up to the first layer folder (view, bloc, ...)
  def feature: . as $p |
    ([range(0; $p | length) as $k | select(["view","views","controller","controllers","bloc","blocs","model","models","repository","repositories","widgets","screens","service","services","api_services"] | index($p[$k]) != null) | $k] | first) as $i |
    if $i == null then ($p[0:(($p | length) - 1)] | join("/")) else ($p[0:$i] | join("/")) end;
  split("\n") | map(select(length > 0) | split("\t")) as $rows |
  ($rows | map(select(.[0] == "K")) | map({key: .[1], value: .[2]}) | from_entries) as $konst |
  # ---- Flutter trigger trace (see the bash part above)
  ($rows | map(select(.[0] == "T")) | map({file: .[1], line: (.[2] | tonumber), called: .[3], ctx: (.[4] // ""), param: (.[5] // "")})) as $T |
  ($rows | map(select(.[0] == "R")) | map({file: .[1], event: .[2], handler: .[3]})) as $R |
  ($rows | map(select(.[0] == "D")) | group_by(.[2]) | map({key: .[0][2], value: (map(.[1]) | unique)}) | from_entries) as $defs |
  ($rows | map(select(.[0] == "S")) | map({file: .[1], line: (.[2] | tonumber), name: .[3], kind: .[4], ctx: (.[5] // ""), param: (.[6] // "")})) as $S |
  ($rows | map(select(.[0] == "W")) | group_by(.[1]) | map({key: .[0][1], value: (map(.[2]) | unique)}) | from_entries) as $W |
  ($rows | map(select(.[0] == "F")) | group_by(.[1]) | map({key: .[0][1], value: (map(.[2]) | unique)}) | from_entries) as $REF |
  ([$rows[] | select(.[0] == "Z") | .[1]]) as $SCREENS |
  ([$rows[] | select(.[0] == "Y") | .[1]] | first // "") as $ROUTER |
  ([$rows[] | select(.[0] == "Q") | {key: .[1], value: .[2]}] | from_entries) as $SID |
  ([$rows[] | select(.[0] == "G") | {line: (.[1] | tonumber), file: .[2]}] | sort_by(.line)) as $GR |
  def merge: {s: (map(.s[]) | unique), u: (map(.u[]) | unique)};
  # screens that use the classes of $f, following widgets inside widgets (3 levels)
  def reach($f; $d): if ($SCREENS | index($f)) then [$f] elif $d > 3 then [] else [($REF[$f] // [])[] | reach(.; $d + 1)[]] | unique end;
  # a non-screen file: the one screen that (through widgets) uses it, else unresolved
  def widget($f; $line):
    reach($f; 0) as $w |
    if ($w | length) == 1 then {s: $w, u: []}
    elif ($w | length) == 0 then {s: [], u: [{file: $f, line: $line, reason: "no screen uses the classes of this file"}]}
    else {s: [], u: [{file: $f, line: $line, reason: "used by \($w | length) screens (\($w | map(split("/") | last) | join(", "))); cannot tell which one triggers it"}]} end;
  # $seen: "file|ctx" already on this path (stops event/method cycles)
  def trace($f; $ctx; $param; $line; $seen):
    ("\($f)|\($ctx)") as $key |
    if ($SCREENS | index($f)) then {s: [$f], u: []}
    elif ($seen | index($key)) then {s: [], u: []}
    elif ($seen | length) > 8 then {s: [], u: [{file: $f, line: $line, reason: "trace longer than 8 hops"}]}
    elif $f == $ROUTER then
      ([$GR[] | select(.line <= $line)] | last) as $g |
      if $g then {s: [$g.file], u: []} else {s: [], u: [{file: $f, line: $line, reason: "router line outside any GoRoute"}]} end
    else
      ($seen + [$key]) as $seen2 |
      ([$R[] | select(.file == $f and (.handler == $ctx or ($param != "" and .event == $param))) | .event] | unique) as $ev |
      if ($ev | length) > 0 then
        [$S[] | select(.kind == "event" and (.name as $n | $ev | index($n)) and (.file as $x | ($defs[.name] // []) | index($x) | not))] as $snd |
        if ($snd | length) == 0 then {s: [], u: [{file: $f, line: $line, reason: "no file sends \($ev | join("/"))"}]}
        else [$snd[] | trace(.file; .ctx; .param; .line; $seen2)] | merge end
      elif ($ctx | test("^_")) then
        [$S[] | select(.kind == "private" and .name == $ctx and .file == $f)] as $snd |
        if ($snd | length) == 0 then widget($f; $line) else [$snd[] | trace(.file; .ctx; .param; .line; $seen2)] | merge end
      elif ($ctx | test("^[a-z]")) and $ctx != "build" then
        ($REF[$f] // []) as $refs |
        [$S[] | select(.kind == "method" and .name == $ctx and .file != $f and (.file as $x | $refs | index($x)))] as $snd |
        if ($snd | length) == 0 then widget($f; $line) else [$snd[] | trace(.file; .ctx; .param; .line; $seen2)] | merge end
      else widget($f; $line) end
    end;
  ([$rows[] | select(.[0] == "C") | "\(.[1])|\(.[4])"] | unique) as $httpPaths |
  [$rows[] | select(.[0] == "C" or (.[0] == "L" and ("\(.[1])|\(.[4])" as $k | $httpPaths | index($k) | not))) | . as $r |
    ($r[4] | if startswith("@") then (sub("^@"; "") | split("/{}")[0]) as $n | (if $konst[$n] then ($konst[$n] + (if ($r[4] | endswith("/{}")) then "/{}" else "" end)) else null end) else . end) as $path |
    {file: $r[1], line: ($r[2] | tonumber), method: (if $r[3] == "?" then null else $r[3] end),
     # a path made only of dynamic parts ("$base/{$x}") cannot be resolved statically
     path: (if ($path // "") | test("^(/\\{\\})+/?$") then null else ($path // null) end), form: $r[5],
     const: (if ($r[4] | startswith("@")) then ($r[4] | sub("^@"; "") | split("/{}")[0]) else null end)} +
    (if $kind == "laravel" then
       ([$ctx[] | select(.file == $r[1] and .from <= ($r[2] | tonumber) and .to >= ($r[2] | tonumber))] | first // {}) as $c |
       {controller: ($c.controller // null), action: ($c.action // null)}
     else
       ($r[6] // "") as $dm |
       ([$T[] | select(.called == $dm and $dm != "")]) as $tc |
       (if ($tc | length) == 0 then {s: [], u: [{file: $r[1], line: ($r[2] | tonumber), reason: "no caller of \(if $dm == "" then "this call" else $dm end) found"}]}
        else [$tc[] | trace(.file; .ctx; .param; .line; [])] | merge end) as $tr0 |
       # every path ended in a cycle: say so instead of returning nothing
       (if ($tr0.s | length) == 0 and ($tr0.u | length) == 0 then {s: [], u: [{file: $r[1], line: ($r[2] | tonumber), reason: "no screen found (every path loops back)"}]} else $tr0 end) as $tr |
       {dart_method: (if $dm == "" then null else $dm end),
        callers: [$tc[] | "\(.file):\(.line)"],
        screen_files: $tr.s,
        screens: [$tr.s[] | $SID[.] // (split("/") | last | sub("\\.dart$"; ""))] | unique,
        trace_unresolved: $tr.u}
     end)
  ] as $calls |
  {repo: $repo, commit: $commit, kind: $kind,
   counts: {calls: ($calls | length), resolved: ([$calls[] | select(.path != null)] | length),
            without_method: ([$calls[] | select(.method == null)] | length),
            unresolved: (([$rows[] | select(.[0] == "U")] | length) + ([$calls[] | select(.path == null)] | length))},
   calls: ($calls | sort_by(.file, .line)),
   unresolved: (([$rows[] | select(.[0] == "U") | {file: .[1], line: (.[2] | tonumber), reason: .[3]}] +
                 [$calls[] | select(.path == null) | {file, line, reason: (if .const then "StringsConst().\(.const) is not a backend baseUrl constant (another service?)" else "path is fully dynamic" end)}]) | sort_by(.file, .line))}') \
  || die "could not build calls.json"
printf '%s\n' "$JSON" > "$OUTD/calls.json"
printf '%s' "$JSON" | "$JQ" -r '"calls: \(.repo) @ \(.commit[0:10]) (\(.kind)): \(.counts.calls) calls, \(.counts.resolved) resolved, \(.counts.without_method) without method, \(.counts.unresolved) unresolved"'
echo "wrote $OUTD/calls.json"
