#!/bin/bash
# screens.sh [--root R] REPO
#
# Laravel repo: every Blade view (resources/views/**/*.blade.php) with the
#   controller methods that render it (controllers.json), the routes that reach
#   those methods (routes.json), and the routes it links to (route('name'),
#   url('/x'), action="/x").
# Flutter repo: every GoRoute in lib/route/router.dart (path, name, screen class)
#   and every *Screen / *Page widget class, with the routes it navigates to
#   (context.go/push/pushNamed/goNamed...).
# Writes _map/<REPO>/screens.json and screens.md.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"; mkdir -p "$OUTD" || die "cannot create $OUTD"
COMMIT=$(repo_stamp "$REPO")
VIEWS=$(tracked_files "$REPO" 'resources/views/*.blade.php')
DARTS=$(tracked_files "$REPO" 'lib/*.dart')

if [ -n "$VIEWS" ]; then
  KIND=blade
  [ -f "$OUTD/controllers.json" ] || die "run controllers.sh $NAME first"
  [ -f "$OUTD/routes.json" ] || die "run routes.sh $NAME first"
  # L<TAB>file<TAB>kind<TAB>target   (kind: route-name | url)
  LINKS=$(cd "$REPO" && printf '%s\n' "$VIEWS" | tr '\n' '\0' | xargs -0 awk '
    { s = $0
      while (match(s, /route\([ \t]*["\047][A-Za-z0-9_.:-]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "L\t%s\troute-name\t%s\t%d\n", FILENAME, v, FNR; s = substr(s, RSTART + RLENGTH) }
      s = $0
      while (match(s, /(url\([ \t]*|href=|action=)["\047]\/[A-Za-z0-9_\/{}.-]*["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "L\t%s\turl\t%s\t%d\n", FILENAME, v, FNR; s = substr(s, RSTART + RLENGTH) } }' 2>/dev/null | sort -u)
  JSON=$( { printf '%s\n' "$VIEWS" | awk '{ print "F\t" $0 }'; printf '%s\n' "$LINKS"; } | redact | "$JQ" -R -s \
      --arg repo "$NAME" --arg commit "$COMMIT" --slurpfile c "$OUTD/controllers.json" --slurpfile r "$OUTD/routes.json" '
    split("\n") | map(select(length > 0) | split("\t")) as $rows |
    ([$c[0].controllers[] as $k | $k.methods[] as $m | $m.views[] | {view: ., controller: $k.fqcn, method: $m.name}]) as $renders |
    ($r[0].routes) as $routes |
    ([$routes[] | select(.name != null) | {key: .name, value: .key}] | from_entries) as $byname |
    ($rows | map(select(.[0] == "L")) | group_by(.[1]) | map({key: .[0][1], value: (map({kind: .[2], target: .[3], line: (.[4] | tonumber)}) | group_by(.kind, .target) | map(min_by(.line)))}) | from_entries) as $links |
    [$rows[] | select(.[0] == "F") | .[1] as $f |
      ($f | sub("^resources/views/"; "") | sub("\\.blade\\.php$"; "") | gsub("/"; ".")) as $id |
      ([$renders[] | select(.view == $id or (.view | gsub("/"; ".")) == $id)] | map({controller, method}) | unique) as $by |
      { id: $id, file: $f,
        partial: ($id | test("(^|\\.)(components?|layouts?|partials?|includes?|modals?|emails?)(\\.|$)|(^|\\.)_")),
        rendered_by: $by,
        routes: ([$by[] as $b | $routes[] | select((.controller // "" | ascii_downcase) == ($b.controller | ascii_downcase) and (.action // "" | ascii_downcase) == ($b.method | ascii_downcase)) | .key] | unique),
        links_to: (($links[$f] // []) | map(if .kind == "route-name" then {route: ($byname[.target] // null), name: .target, line} else {url: .target, line} end) | unique_by(.route // .url, .name))
      }] | sort_by(.id) as $screens |
    {repo: $repo, commit: $commit, kind: "blade",
     counts: {screens: ($screens | length), partials: ([$screens[] | select(.partial)] | length),
              rendered_by_controller: ([$screens[] | select(.rendered_by | length > 0)] | length),
              reachable_by_route: ([$screens[] | select(.routes | length > 0)] | length)},
     screens: $screens}') || die "could not build screens.json"

  # ---- page JavaScript: which page triggers each AJAX call (link-apis.sh joins
  # the URL to a Frontend route -> controller -> backend call)
  # Blade structure, one row per fact:
  #   I file view-id (extends/include/component)   S file js-path (script src)
  #   E file id      C file class      O file fn (on*="fn(")      A file action-url-or-R:name line
  STRUCT=$(cd "$REPO" && printf '%s\n' "$VIEWS" | tr '\n' '\0' | xargs -0 awk '
    { s = $0
      t = s; while (match(t, /@(extends|include|includeIf|includeWhen|includeUnless|includeFirst|component|each)\([^"\047)]*["\047][A-Za-z0-9_.:\/-]+["\047]/)) { v = substr(t, RSTART, RLENGTH); k = (v ~ /^@extends/) ? "extends" : "include"; sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); gsub(/\//, ".", v); print "I\t" FILENAME "\t" v "\t" k; t = substr(t, RSTART + RLENGTH) }
      t = s; while (match(t, /<x-[a-z0-9][a-z0-9.-]*/)) { v = substr(t, RSTART + 3, RLENGTH - 3); print "I\t" FILENAME "\tcomponents." v "\tinclude"; t = substr(t, RSTART + RLENGTH) }
      t = s; while (match(t, /<script[^>]*src=("[^"]*"|\047[^\047]*\047)/)) { v = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); if (match(v, /[A-Za-z0-9_.\/@-]*\.js/)) { p = substr(v, RSTART, RLENGTH); sub(/^\//, "", p); print "S\t" FILENAME "\tpublic/" p } }
      t = s; while (match(t, /[ \t]id=["\047][A-Za-z0-9_-]+["\047]/)) { v = substr(t, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); print "E\t" FILENAME "\t" v; t = substr(t, RSTART + RLENGTH) }
      t = s; while (match(t, /[ \t]class=["\047][^"\047]*["\047]/)) { v = substr(t, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); n = split(v, cl, /[ \t]+/); for (i = 1; i <= n; i++) if (cl[i] ~ /^[A-Za-z_-][A-Za-z0-9_-]*$/) print "C\t" FILENAME "\t" cl[i]; t = substr(t, RSTART + RLENGTH) }
      t = s; while (match(t, /[ \t]on[a-z]+=["\047][ \t]*(return[ \t]+)?[A-Za-z_$][A-Za-z0-9_$]*[ \t]*\(/)) { v = substr(t, RSTART, RLENGTH); sub(/^[^"\047]*["\047][ \t]*(return[ \t]+)?/, "", v); sub(/[ \t]*\($/, "", v); print "O\t" FILENAME "\t" v; t = substr(t, RSTART + RLENGTH) }
      t = s; while (match(t, /[ \t]action=("[^"]*"|\047[^\047]*\047)/)) { v = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v)
        if (v ~ /route\(/) { sub(/^[^(]*\([ \t]*["\047]/, "", v); sub(/["\047].*/, "", v); print "A\t" FILENAME "\tR:" v "\t" FNR }
        else if (v ~ /url\(/) { sub(/^[^(]*\([ \t]*["\047]/, "", v); sub(/["\047].*/, "", v); if (v !~ /^\//) v = "/" v; print "A\t" FILENAME "\t" v "\t" FNR }
        else if (v ~ /^\//) print "A\t" FILENAME "\t" v "\t" FNR } }' 2>/dev/null | sort -u)
  # JS files pages load (tracked, not libraries)
  JSF=$(printf '%s\n' "$STRUCT" | awk -F '\t' '$1 == "S" { print $3 }' | sort -u | while IFS= read -r f; do git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && printf '%s\n' "$f"; done |
    grep -v -i -E '/(external|vendor|libs?|plugins)/|\.min\.js$|/(jquery|sweetalert|bootstrap|datatables|select2|moment|chart|popper|toastr|summernote|flatpickr|cropper)[^/]*$' | awk "$ATREYA_SECRET_FILTER")
  JSROWS=$(cd "$REPO" && { printf '%s\n' "$VIEWS"; printf '%s\n' "$JSF"; } | grep . | tr '\n' '\0' | xargs -0 awk -f "$ATREYA_LIB/jsscan.awk" 2>/dev/null)
  BASEF=$(mktemp "${TMPDIR:-/tmp}/atreya-screens.XXXXXX") || die "mktemp failed"
  trap 'rm -f "$BASEF"' EXIT
  printf '%s\n' "$JSON" > "$BASEF"
  JSON=$( { printf '%s\n' "$STRUCT"; printf '%s\n' "$JSROWS"; } | redact | "$JQ" -R -s --slurpfile basef "$BASEF" '
    split("\n") | map(select(length > 0) | split("\t")) as $rows | $basef[0] as $base |
    def vid: sub("^resources/views/"; "") | sub("\\.blade\\.php$"; "") | gsub("/"; ".");
    ($base.screens | map({key: .file, value: .}) | from_entries) as $byfile |
    ($base.screens | map({key: .id, value: .file}) | from_entries) as $fileof |
    def links($k): $rows | map(select(.[0] == "I" and (.[3] // "include") == $k)) | group_by(.[1]) | map({key: .[0][1], value: ([.[] | $fileof[.[2]] // empty] | unique)}) | from_entries;
    links("extends") as $ext | links("include") as $inc |
    def grp($k): $rows | map(select(.[0] == $k)) | group_by(.[1]) | map({key: .[0][1], value: (map(.[2]) | unique)}) | from_entries;
    grp("S") as $src | grp("E") as $ids | grp("C") as $cls | grp("O") as $onfn |
    # every blade file a page is made of: itself, the layouts it extends (and theirs),
    # and the partials/components any of those include (5 levels). The @extends of
    # an INCLUDED view is not followed: Blade lays out only the page being rendered
    # (a full page reused as a component does not bring its own layout along).
    def closure($f; $d; $incl): [$f] + (if $d > 5 then [] else
        [(if $incl then [] else ($ext[$f] // []) end)[] | closure(.; $d + 1; false)[]] +
        [($inc[$f] // [])[] | closure(.; $d + 1; true)[]] end) | unique;
    ([$base.screens[] | select(.partial | not) | .file]) as $pages |
    ([$pages[] | {key: ., value: closure(.; 0; false)}] | from_entries) as $clo |
    ([$pages[] | . as $p | {key: $p, value: ([$clo[$p][] | ($src[.] // [])[]] | unique)}] | from_entries) as $js |
    # pages that load a file (JS: through a script tag; blade: as part of the page)
    def loaders($f): if ($f | endswith(".blade.php")) then [$pages[] | select($clo[.] | index($f))] else [$pages[] | select($js[.] | index($f))] end;
    ([$rows[] | select(.[0] == "X") | {file: .[1], name: .[3], kind: .[4], ctx: (.[5] // "")}]) as $X |
    def has($p; $tok): if ($tok | startswith("#")) then any($clo[$p][]; ($ids[.] // []) | index($tok[1:])) else any($clo[$p][]; ($cls[.] // []) | index($tok[1:])) end;
    def tokens($sel): [$sel | scan("[#.][A-Za-z0-9_-]+")];
    # pages that call function $fn themselves: on*="fn(" in their blade, or a call in a file only they load
    def calls_fn($p; $fn): any($clo[$p][]; ($onfn[.] // []) | index($fn)) or
      any($X[]; .name == $fn and (.file as $f | ($clo[$p] | index($f)) or (($js[$p] | index($f)) and (loaders($f) | length) == 1)));
    def credit($f; $kind; $name; $d):
      loaders($f) as $L |
      if ($L | length) == 0 then {p: [], r: "no page loads \($f)"}
      elif ($L | length) == 1 then {p: $L, how: "only page that loads it"}
      elif $kind == "sel" then
        tokens($name) as $tk |
        if ($tk | length) == 0 then {p: [], r: "shared by \($L | length) pages; selector \($name) has no #id/.class to look for"}
        else [$L[] | . as $p | select(all($tk[]; has($p; .)))] as $hit |
          if ($hit | length) > 0 then {p: $hit, how: "page has \($name)"} else {p: [], r: "shared by \($L | length) pages; none has \($name)"} end end
      elif $kind == "fn" then
        ([$L[] | select(calls_fn(.; $name))] +
         (if $d < 3 then [$X[] | select(.file == $f and .name == $name and .ctx != $name) | credit($f; .kind; .ctx; $d + 1).p[]] else [] end) | unique) as $hit |
        if ($hit | length) > 0 then {p: $hit, how: "page triggers \($name)()"} else {p: [], r: "shared by \($L | length) pages; cannot tell which one triggers \($name)()"} end
      else {p: [], r: "runs on load on every page that loads \($f) (\($L | length) pages)"} end;
    ([$rows[] | select(.[0] == "J") | {file: .[1], line: (.[2] | tonumber), method: (if .[3] == "?" then null else .[3] end), url: .[4], kind: .[5], ctx: (.[6] // "")}] | unique) as $J |
    $base + {
      js_files: ($js | [.[]] | add // [] | unique),
      js_calls: [$J[] | . as $c | credit($c.file; $c.kind; $c.ctx; 0) as $cr |
        {file, line, method, url, context: (if .kind == "load" then "page load" else "\(.kind) \(.ctx)" end),
         pages: [$cr.p[] | vid], how: ($cr.how // null), unresolved: ($cr.r // null)}],
      js_unresolved: [$rows[] | select(.[0] == "U") | {file: .[1], line: (.[2] | tonumber), reason: .[3]}],
      forms: [$rows[] | select(.[0] == "A") | {file: .[1], line: (.[3] | tonumber), action: .[2]}],
      screens: [$base.screens[] | . + (if .partial then {} else {parts: ($clo[.file] // [.file]), scripts: ($js[.file] // [])} end)]
    } | .counts += {js_calls: (.js_calls | length), js_calls_credited: ([.js_calls[] | select(.pages | length > 0)] | length),
                    js_calls_unresolved: (([.js_calls[] | select(.unresolved)] | length) + (.js_unresolved | length))}') || die "could not add page JS to screens.json"
elif [ -n "$DARTS" ]; then
  KIND=flutter
  ROUTER=lib/route/router.dart
  GR=""
  if printf '%s\n' "$DARTS" | grep -qx "$ROUTER"; then
    # G<TAB>path<TAB>name<TAB>class<TAB>line   (class = last *Screen/*Page/*View(...) in the GoRoute block)
    GR=$(awk '
      function flush() { if (inr) printf "G\t%s\t%s\t%s\t%d\n", p, nm, cl, ln; inr = 0 }
      /GoRoute\(/ { flush(); inr = 1; p = ""; nm = ""; cl = ""; ln = NR }
      inr && match($0, /path:[ \t]*["\047][^"\047]*["\047]/) { p = substr($0, RSTART, RLENGTH); sub(/^path:[ \t]*["\047]/, "", p); sub(/["\047]$/, "", p) }
      inr && match($0, /name:[ \t]*["\047][^"\047]*["\047]/) { nm = substr($0, RSTART, RLENGTH); sub(/^name:[ \t]*["\047]/, "", nm); sub(/["\047]$/, "", nm) }
      # framework page wrappers (CustomTransitionPage, MaterialPage, ...) are not screens
      inr { s = $0; while (match(s, /[A-Z][A-Za-z0-9_]*(Screen|Page|View)[ \t]*\(/)) { c = substr(s, RSTART, RLENGTH); sub(/[ \t]*\($/, "", c); s = substr(s, RSTART + RLENGTH)
              if (c !~ /^(CustomTransitionPage|MaterialPage|CupertinoPage|NoTransitionPage|TransitionPage|PageView|ListView|GridView|WebView|InAppWebView)$/) cl = c } }
      END { flush() }' "$REPO/$ROUTER")
  fi
  # S<TAB>class<TAB>file   N<TAB>file<TAB>kind<TAB>target
  SC=$(cd "$REPO" && printf '%s\n' "$DARTS" | tr '\n' '\0' | xargs -0 awk '
    match($0, /class[ \t]+[A-Z][A-Za-z0-9_]*(Screen|Page)[ \t]+extends[ \t]+(StatelessWidget|StatefulWidget|ConsumerWidget|ConsumerStatefulWidget|HookWidget)/) {
      c = substr($0, RSTART, RLENGTH); sub(/^class[ \t]+/, "", c); sub(/[ \t]+extends.*/, "", c); printf "S\t%s\t%s\n", c, FILENAME }
    # another screen built inside this file (tabs, child widgets): E<TAB>file<TAB>class<TAB>line
    /^[ \t]*\/\// { next }
    { s = $0
      while (match(s, /[A-Z][A-Za-z0-9_]*(Screen|Page)[ \t]*\(/)) { v = substr(s, RSTART, RLENGTH); sub(/[ \t]*\($/, "", v); s = substr(s, RSTART + RLENGTH)
        if (v !~ /^(CustomTransitionPage|MaterialPage|CupertinoPage|NoTransitionPage|TransitionPage)$/ && $0 !~ /class[ \t]+/) printf "E\t%s\t%s\t%d\n", FILENAME, v, FNR } }
    { s = $0
      while (match(s, /context\.(go|push|pushReplacement|replace)\([ \t]*["\047][^"\047]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); sub(/\?.*/, "", v); printf "N\t%s\tpath\t%s\t%d\n", FILENAME, v, FNR; s = substr(s, RSTART + RLENGTH) }
      s = $0
      while (match(s, /context\.(goNamed|pushNamed|pushReplacementNamed|replaceNamed)\([ \t]*["\047][^"\047]+["\047]/)) { v = substr(s, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", v); sub(/["\047]$/, "", v); printf "N\t%s\tname\t%s\t%d\n", FILENAME, v, FNR; s = substr(s, RSTART + RLENGTH) } }' 2>/dev/null | sort -u)
  JSON=$(printf '%s\n%s\n' "$GR" "$SC" | redact | "$JQ" -R -s --arg repo "$NAME" --arg commit "$COMMIT" --arg router "$ROUTER" '
    split("\n") | map(select(length > 0) | split("\t")) as $rows |
    ($rows | map(select(.[0] == "G")) | map({path: .[1], name: (if .[2] == "" then null else .[2] end), class: (if .[3] == "" then null else .[3] end), line: (.[4] | tonumber)})) as $gr |
    ($rows | map(select(.[0] == "S")) | map({key: .[1], value: .[2]}) | from_entries) as $files |
    ($rows | map(select(.[0] == "N")) | group_by(.[1]) | map({key: .[0][1], value: (map({kind: .[2], target: .[3], line: (.[4] | tonumber)}) | group_by(.kind, .target) | map(min_by(.line)))}) | from_entries) as $nav |
    ([$gr[] | {key: (.name // ""), value: .path}] | from_entries) as $pathByName |
    ([$gr[].class // empty] + ($files | keys) | unique) as $classes |
    [$classes[] as $c | ($files[$c] // null) as $f | {
      id: $c, file: $f,
      routes: [$gr[] | select(.class == $c) | {path, name, line}],
      navigates_to: (if $f == null then [] else (($nav[$f] // []) | map(if .kind == "name" then {path: ($pathByName[.target] // null), name: .target, line} else {path: .target, line} end) | unique_by(.path, .name)) end),
      embeds: (if $f == null then [] else [$rows[] | select(.[0] == "E" and .[1] == $f and .[2] != $c and ($files[.[2]] != null)) | {screen: .[2], line: (.[3] | tonumber)}] | group_by(.screen) | map(min_by(.line)) end)
    }] | sort_by(.id) as $screens |
    {repo: $repo, commit: $commit, kind: "flutter", router: $router,
     counts: {screens: ($screens | length), go_routes: ($gr | length),
              routes_without_screen_class: ([$gr[] | select(.class == null)] | length),
              screen_classes_without_route: ([$screens[] | select(.routes | length == 0)] | length),
              screens_file_not_found: ([$screens[] | select(.file == null)] | length)},
     go_routes: $gr, screens: $screens}') || die "could not build screens.json"
else
  die "$NAME has neither resources/views nor lib/*.dart"
fi
printf '%s\n' "$JSON" > "$OUTD/screens.json"

printf '%s' "$JSON" | "$JQ" -r '
  "# Screens: \(.repo) (\(.kind))\n",
  "Built from commit `\(.commit)` by scripts/screens.sh.\n",
  (.counts | to_entries | map("\(.key): \(.value)") | join(" · ")), "",
  if .kind == "blade" then
    ("| View | Rendered by | Routes | Links to |", "|---|---|---|---|",
     (.screens[] | select(.partial | not) | "| `\(.id)` | \(.rendered_by | map((.controller | split("\\") | last) + "@" + .method) | join(", ")) | \(.routes | map("`\(.)`") | join(", ")) | \(.links_to | map(.route // .name // .url) | map(select(. != null)) | join(", ")) |"),
     "", "Partials (layouts, components, modals, emails): \(.screens | map(select(.partial)) | length)")
  else
    ("| Screen | File | GoRoute path(s) | Navigates to |", "|---|---|---|---|",
     (.screens[] | "| \(.id) | `\(.file // "not found")` | \(.routes | map("`\(.path)`") | join(", ")) | \(.navigates_to | map(.path // .name) | map(select(. != null)) | join(", ")) |"))
  end' > "$OUTD/screens.md"

printf '%s' "$JSON" | "$JQ" -r '"screens: \(.repo) @ \(.commit[0:10]) (\(.kind)): " + (.counts | to_entries | map("\(.key) \(.value)") | join(", "))'
echo "wrote $OUTD/screens.json and screens.md"
