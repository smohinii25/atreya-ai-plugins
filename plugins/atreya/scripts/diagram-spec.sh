#!/bin/bash
# diagram-spec.sh [--root R] MODULE KIND [options]       (prints the spec JSON)
#
#   er                              the module's tables (columns from migrations)
#                                   + model relations between them
#   sequence --routes "K1,K2" [--client REPO] [--name N] [--title T]
#                                   screen -> client caller -> route ->
#                                   controller@method -> tables, then the response
#                                   with the HTTP codes found in the code
#   flow --platform app|web         the module's screens on that platform and
#                                   their navigation; targets outside the module
#                                   are "external" boxes
# Built only from _map data (fact pack, screens/controllers/models.json), so the
# same commit and options give the same spec. Every box and arrow carries a
# source. The spec's "options" records the options given (routes, client,
# callers, name, title, platform) so the diagram can be regenerated exactly.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
ID="${ARGS[0]:-}"; KIND="${ARGS[1]:-}"
ROUTES=""; CLIENT=""; CALLERS=""; NAME=""; TITLE=""; PLATFORM=""
set -- "${ARGS[@]:2}"
while [ $# -gt 0 ]; do case "$1" in
  --routes) ROUTES="$2"; shift 2 ;; --client) CLIENT="$2"; shift 2 ;; --callers) CALLERS="$2"; shift 2 ;; --name) NAME="$2"; shift 2 ;;
  --title) TITLE="$2"; shift 2 ;; --platform) PLATFORM="$2"; shift 2 ;; *) die "unknown argument $1" ;; esac; done
case "$KIND" in er|sequence|flow) ;; *) die "usage: diagram-spec.sh --root R MODULE er|sequence|flow [options]" ;; esac
FJ="$DOCS/_map/_modules/$ID/facts.json"
[ -f "$FJ" ] || die "no fact pack for $ID (run module-facts.sh $ID)"
BACKEND=$("$JQ" -r '.backend' "$FJ"); BD="$DOCS/_map/$BACKEND"
# options: the arguments this spec was made with (only those given), so a re-run
# can repeat them exactly: make-diagram.sh MODULE KIND <options as --key value>
COMMON=$("$JQ" -c --arg date "$(today)" --arg routes "$ROUTES" --arg client "$CLIENT" --arg callers "$CALLERS" \
  --arg name "$NAME" --arg title "$TITLE" --arg platform "$PLATFORM" '
  {module: .module.id, date: $date, commits,
   options: ({routes: $routes, client: $client, callers: $callers, name: $name, title: $title, platform: $platform} | with_entries(select(.value != "")))}' "$FJ")
# every client screen (id, file), to cite pages outside the module
TMPS=$(mktemp "${TMPDIR:-/tmp}/atreya-scr.XXXXXX") || die "mktemp failed"
trap 'rm -f "$TMPS"' EXIT
for s in "$DOCS"/_map/*/screens.json; do [ -f "$s" ] && "$JQ" -c '{repo, screens: [.screens[] | select(.file != null) | {id, file}]}' "$s"; done | "$JQ" -s . > "$TMPS"

case "$KIND" in
er)
  "$JQ" --argjson c "$COMMON" --slurpfile mj "$BD/models.json" --arg be "$BACKEND" --arg title "$TITLE" '
    ($mj[0].models | map({key: .fqcn, value: .}) | from_entries) as $byFq |
    ($mj[0].models | map({key: (.fqcn | split("\\") | last), value: .}) | from_entries) as $byShort |
    ([.tables[].name]) as $tabs |
    $c + {kind: "er", name: "er", title: (if $title != "" then $title else "\(.module.name): data model (columns from migrations only)" end),
      nodes: [.tables[] | . as $t | {id: .name, label: .name, type: "table",
               columns: ((.columns // []) | map(.name)),
               source: ($mj[0].models | map(select(.table == $t.name)) | first | if . then "\($be):\(.file)" else "" end)}],
      edges: [$mj[0].models[] | select(.table as $x | $tabs | index($x)) | . as $m | .relations[] |
               (($byFq[.target] // $byShort[.target | split("\\") | last]) // null) as $tm |
               select($tm != null and ($tm.table as $x | $tabs | index($x)) and $tm.table != $m.table) |
               {from: $m.table, to: $tm.table, label: "\(.method): \(.type)", source: "\($be):\($m.file)"}] | unique_by(.from, .to, .label)}' "$FJ"
  ;;
sequence)
  [ -n "$ROUTES" ] || die "sequence needs --routes \"METHOD uri,...\""
  "$JQ" --argjson c "$COMMON" --arg routes "$ROUTES" --arg client "$CLIENT" --arg name "$NAME" --arg title "$TITLE" \
        --slurpfile cj "$BD/controllers.json" --arg be "$BACKEND" --arg callers "$CALLERS" --slurpfile scr "$TMPS" '
    def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-");
    ([$cj[0].controllers[] as $k | $k.methods[] | {key: ((($k.fqcn | split("\\") | last) + "@" + .name) | ascii_downcase), value: "\($be):\($k.file):\(.lines[0])"}] | from_entries) as $msrc |
    . as $F | ($routes | split(",") | map(gsub("^ +| +$"; ""))) as $keys |
    ([$keys[] as $k | $F.backend_routes[] | select(.key == $k)]) as $R |
    (if ($R | length) != ($keys | length) then error("unknown route(s) for this module: \([$keys[] | select(. as $k | $R | map(.key) | index($k) | not)] | join(", "))") else . end) |
    ([$R[] as $r | $F.api_calls[] | select(.route == $r.key and .status == "matched" and ($client == "" or .client == $client) and ($callers == "" or (.caller as $x | $callers | split(",") | map(gsub("^ +| +$"; "")) | index($x))))] | unique_by(.client, .caller, .route)) as $calls |
    # keep the first occurrence, in order (unique_by would sort)
    def uniq_ordered(f): reduce .[] as $e ([]; if any(.[]; f == ($e | f)) then . else . + [$e] end);
    # the screens behind a call; App calls are traced to a feature folder, so
    # several screens may share one call: show them as one box, all named
    def screen_of($call): ($call.pages | map(select(test("^(GET|POST|PUT|PATCH|DELETE|ANY) ") | not))) as $ps |
      if ($ps | length) == 0 then null else (([$F.screens[] | select(.id == $ps[0])] | first) // ([$scr[0][] | select(.repo == $call.client) | .screens[] | select(.id == $ps[0]) | {file: "\($call.client):\(.file)"}] | first)) as $s |
        {id: "scr-\($ps | join("-") | slug)", label: (if ($ps | length) == 1 then $ps[0] else "\($ps | length) screens" end),
         sub: (if ($ps | length) == 1 then null else ($ps | join(", ")) end), type: "screen", source: ($s.file // "")} end;
    # tables per route; more than 3 become one "N tables" box naming them all
    def tabs($r): [$calls[] | select(.route == $r.key) | .tables[]] | unique;
    def tnodes($r): tabs($r) as $T | ($msrc[$r.controller | ascii_downcase] // "") as $src |
      if ($T | length) > 3 then [{id: "tbl-grp-\($r.controller | slug)", label: "\($T | length) tables", sub: ($T | join(", ")), type: "db", source: $src}]
      else [$T[] | {id: "tbl-\(. | slug)", label: ., type: "db", source: $src}] end;
    # participants (dedup, ordered)
    ([ ($calls[] | screen_of(.) // empty),
       ($calls[] | {id: "cli-\(.client | slug)-\(.caller | slug)", label: .caller, sub: .client, type: "client", source: .source}),
       ($R[] | {id: "rt-\(.key | slug)", label: .key, type: "route", source: .source}),
       ($R[] | {id: "ctl-\(.controller | slug)", label: .controller, type: "controller", source: ($msrc[.controller | ascii_downcase] // .controller_source // "")}),
       ($R[] | tnodes(.)[])
     ] | unique_by(.id) | sort_by((.type as $t | ["screen", "client", "route", "controller", "db"] | index($t)), .id)) as $nodes |
    # messages, route by route in the given order
    ([$R[] as $r |
      ($calls[] | select(.route == $r.key)) as $call |
      (screen_of($call)) as $s |
      (if $s then [{from: $s.id, to: "cli-\($call.client | slug)-\($call.caller | slug)", label: "uses \($call.caller)", source: $call.source}] else [] end) +
      [{from: "cli-\($call.client | slug)-\($call.caller | slug)", to: "rt-\($r.key | slug)", label: "\($call.method // "?") \($call.endpoint)", source: $call.source}]
     ] | add // []) as $calledges |
    ([$R[] as $r |
      [{from: "rt-\($r.key | slug)", to: "ctl-\($r.controller | slug)", label: "\($r.controller)", source: $r.source}] +
      [tnodes($r)[] | {from: "ctl-\($r.controller | slug)", to: .id, label: "uses \(.label)", source: .source}] +
      (([$r.errors[] | .http | select(. != null)] | unique) as $codes |
       ([$calls[] | select(.route == $r.key)] | first) as $call0 |
       if $call0 then [{from: "ctl-\($r.controller | slug)", to: "cli-\($call0.client | slug)-\($call0.caller | slug)", label: "response \(if ($codes | length) > 0 then ($codes | join("/")) else "" end)", source: (($r.errors | map(select(.http != null)) | first | .source) // $r.source)}] else [] end)
     ] | add // []) as $backedges |
    $c + {kind: "sequence", name: (if $name != "" then $name else "seq-\($keys[0] | slug)" end),
          title: (if $title != "" then $title else "\($F.module.name): \($keys | join(", "))" end),
          nodes: $nodes, edges: (($calledges + $backedges) | uniq_ordered([.from, .to, .label]))}' "$FJ"
  ;;
flow)
  case "$PLATFORM" in app|web) ;; *) die "flow needs --platform app|web" ;; esac
  APPREPO=""; WEBREPO=""
  for d in "$DOCS"/_map/*/; do r=${d%/}; r=${r##*/}; [ -f "$d/screens.json" ] || continue
    k=$("$JQ" -r '.kind' "$d/screens.json"); [ "$k" = flutter ] && APPREPO=$r
    [ "$k" = blade ] && [ "$r" != "$BACKEND" ] && WEBREPO=$r; done
  REPO=$([ "$PLATFORM" = app ] && echo "$APPREPO" || echo "$WEBREPO")
  [ -n "$REPO" ] || die "no $PLATFORM repo mapped"
  "$JQ" --argjson c "$COMMON" --arg repo "$REPO" --arg plat "$PLATFORM" --arg title "$TITLE" --slurpfile sj "$DOCS/_map/$REPO/screens.json" '
    def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-");
    def asset: test("\\.(svg|png|jpe?g|gif|webp|ico|css|js|pdf|json)$"; "i");
    $sj[0].screens as $all |
    ([.screens[] | select(.repo == $repo)]) as $mine |
    ([$mine[].id]) as $mineIds |
    # resolve a navigation target to a screen id (or null)
    def target($l):
      if $plat == "app" then ([$all[] | select(any(.routes[]?; .path == $l.path))] | first | .id) // null
      else ($l.route // null) as $rk | if $rk then ([$all[] | select(.partial | not) | select((.routes // []) | index($rk))] | first | .id) // null else null end end;
    def tlabel($l): if $plat == "app" then $l.path else ($l.route // $l.url) end;
    ([$mine[] | . as $s | ($s.links_to // [])[] | select((.url // "") | asset | not) | select(.path != null or .route != null or .url != null) |
       target(.) as $t | {from: ("s-" + ($s.id | slug)), tid: $t, tlabel: tlabel(.), line: .line, file: ($s.file | sub("^[^:]+:"; ""))}] +
     # screens built inside another screen (tabs): "contains"
     [$mine[] | . as $s | ([$all[] | select(.id == $s.id)] | first | .embeds // [])[] |
       {from: ("s-" + ($s.id | slug)), tid: .screen, tlabel: "contains", line: .line, file: ($s.file | sub("^[^:]+:"; ""))}]) as $nav |
    $c + {kind: "flow", name: "flow-\($plat)", title: (if $title != "" then $title else "\(.module.name): screen flow (\($plat))" end),
      nodes: ([$mine[] | {id: ("s-" + (.id | slug)), label: .id,
                           sub: ((.routes // []) | map(if type == "object" then .path else . end) | join(", ") | if . == "" then null else . end),
                           type: "screen", source: .file}] +
              ([$nav[] | select(.tid == null or (.tid as $t | $mineIds | index($t) | not)) |
                {id: ("x-" + ((.tid // .tlabel) | slug)), label: (.tid // .tlabel), sub: (if .tid then .tlabel else null end), type: "external", source: ""}] | unique_by(.id))),
      edges: ([$nav[] | {from, to: (if .tid != null and (.tid as $t | $mineIds | index($t)) then "s-" + (.tid | slug) else "x-" + ((.tid // .tlabel) | slug) end),
                         label: .tlabel, source: "\($repo):\(.file):\(.line)"}] | unique_by(.from, .to))}' "$FJ"
  ;;
esac
