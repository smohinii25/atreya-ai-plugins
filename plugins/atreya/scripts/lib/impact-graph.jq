# impact-graph.jq: v2 impact facts (indirect dependencies) from the v1 facts.
# Run by scripts/impact-facts.sh only:
#   jq -n --slurpfile Mf modules.json --slurpfile Df data.json --slurpfile Ff facts.json \
#         --argjson depth N -f impact-graph.jq
# Deterministic: same _map + seeds + depth -> same output. Rules are in
# references/impact-guide.md ("Indirect dependencies"); in short:
#   the change travels UP    method -> routes it handles -> client callers
#                            class  -> methods that use it (services, listeners...)
#                     DOWN   changed table -> methods that read/write it
#                            changed method -> listeners of the events it emits
#                            changed client code -> backend route it calls (stops there)
#   depth  = module hops from the change (crossing into another module = +1)
#   a node already on the current path = a cycle (recorded, not followed)
#   NOT traced (listed under not_affected / data_flow): tables only read or only
#   written by the changed code, classes the changed code calls.
$Mf[0] as $M | $Df[0] as $D | $Ff[0] as $F | $M.backend as $be |
def same($a; $b): ($a // "" | ascii_downcase) == ($b // "" | ascii_downcase);
def short: split("\\") | last;
def routesof($r): [($D[$r].routes.routes // [])[] | select(.shadowed != true)];
def links($r): ($D[$r]["api-links"].links // []);
def kind($r): ($D[$r].screens.kind // "");
def owns_file($m; $r; $p): any(($m.repos // [])[]; .repo == $r and (((.files // []) | index($p)) or any((.paths // [])[]; . as $x | $p | startswith($x)))) or any(($m.screens // [])[]; .repo == $r and .path == $p);
def owners($r; $p): [$M.modules[] | select(owns_file(.; $r; $p)) | .id];
def route_owners($r; $k): if $r == $be then [$M.modules[] | select((.routes // []) | index($k)) | .id]
  else [$M.modules[] | select(any((.web_routes // [])[]; .repo == $r and (.routes | index($k)))) | .id] end;
def table_users($t): [$M.modules[] | select((.tables // []) | index($t)) | .id];
def direct_ids: [$F.direct_modules[].id];

# ---- every method of every mapped class (controllers + other app classes)
[ $D | keys[] as $r | ($D[$r].controllers // {}) as $c |
  ( (($c.controllers // [])[] | {ctl: true, ckind: "controller"} + .), (($c.classes // [])[] | {ctl: false, ckind: (.kind // "other")} + .) ) as $k |
  $k.methods[] | {repo: $r, fqcn: $k.fqcn, file: $k.file, ctl: $k.ctl, ckind: $k.ckind, name, from: .lines[0], to: .lines[1],
                  tables: (.tables // []), writes: (.writes // []), uses: (.uses // []), transaction: (.transaction // false)} ] as $AM |

def mlabel($x): "\($x.fqcn | short)@\($x.name)";
def mnode($x): {id: "method:\($x.repo):\($x.fqcn)@\($x.name)", type: "method", label: mlabel($x), repo: $x.repo,
                module: (owners($x.repo; $x.file) | .[0]), cite: "\($x.repo):\($x.file):\($x.from)"};
def rnode($r; $x): {id: "route:\($r):\($x.key)", type: (if $r == $be then "route" else "web-route" end), label: $x.key, repo: $r,
                    module: (route_owners($r; $x.key) | .[0]), cite: "\($r):\($x.file):\($x.line)"};
def tnode($t): {id: "table:\($t)", type: "table", label: $t, repo: null, module: null, cite: null};
def cnode($r; $fq): ([$AM[] | select(.repo == $r and .fqcn == $fq) | .file] | .[0]) as $f |
  {id: "class:\($r):\($fq)", type: "class", label: ($fq | short), repo: $r,
   module: (if $f then owners($r; $f) | .[0] else null end), cite: (if $f then "\($r):\($f)" else null end)};
def knode($l): {id: "caller:\($l.client):\($l.caller)", type: (if kind($l.client) == "flutter" then "app-caller" else "web-caller" end),
                label: "\($l.caller) (\($l.client))", repo: $l.client, module: $l.caller_module, pages: ($l.pages // []), cite: "\($l.client):\($l.source)"};
def route_rec($r; $k): (routesof($r) | map(select(.key == $k)) | .[0]);

# ---- neighbours of an affected node: [{node, type, dir, cite, nfrom (edge runs neighbour -> node), stop}]
def users_of($r; $fq): [ $AM[] | select(.repo == $r) | . as $u | ($u.uses[] | select(.class == $fq)) |
  {node: mnode($u), type: "uses", dir: "up", cite: "\($u.repo):\($u.file):\(.lines[0])", nfrom: true} ];
def nbrs($n; $x):
  if $n.type == "method" then
    [ routesof($x.repo)[] | select(.controller != null and same(.controller; $x.fqcn) and same(.action; $x.name)) |
      {node: rnode($x.repo; .), type: "handled_by", dir: "up", cite: "\($x.repo):\(.file):\(.line)", nfrom: true} ] +
    (if $x.ctl then [] else users_of($x.repo; $x.fqcn) end) +
    [ ($x.uses[] | select(.kind == "event")) as $e |
      (($D[$x.repo].controllers.events // [])[] | select(.event == $e.class)) as $ev | $ev.listeners[] as $l |
      ([$AM[] | select(.repo == $x.repo and .fqcn == $l)] | if length > 0 then .[] | {node: mnode(.), m: .} else {node: cnode($x.repo; $l)} end) |
      . + {type: "listens", dir: "down", cite: "\($x.repo):\($ev.source)", nfrom: false} ]
  elif $n.type == "route" then
    [ ($D | keys[]) as $c | links($c)[] | select(.route == $n.label) |
      {node: knode(. + {client: $c}), type: "calls", dir: "up", cite: "\($c):\(.source)", nfrom: true} ]
  elif $n.type == "class" then users_of($n.repo; $x.fqcn)
  elif $n.type == "table" then
    [ $AM[] | select((.tables | index($n.label)) or any(.writes[]; .table == $n.label)) | . as $u |
      ([$u.writes[] | select(.table == $n.label) | .lines[0]] | .[0]) as $wl |
      {node: mnode($u), type: (if $wl then "writes" else "reads" end), dir: "down", cite: "\($u.repo):\($u.file):\($wl // $u.from)", nfrom: true} ]
  else [] end;
# the method record behind a method node (for nbrs)
def mrec($id): ([$AM[] | select("method:\(.repo):\(.fqcn)@\(.name)" == $id)] | .[0]);

# ---- changed nodes
([ $F.spans[] | select(.kind != "route-line") as $s | $AM[] | select(.repo == $s.repo and .file == $s.path and .from <= $s.to and $s.from <= .to) ]
 | unique_by("\(.repo) \(.fqcn) \(.name)")) as $chm |
([ ($chm[] | mnode(.) + {x: .}),
   ($F.backend_routes[] | route_rec($be; .key) as $r | select($r != null) | rnode($be; $r)),
   ($F.web_routes[] | . as $w | route_rec($w.repo; $w.key) as $r | select($r != null) | rnode($w.repo; $r)),
   ($F.tables.changed[] | tnode(.name)) ] | unique_by(.id)
 | map(. + {hops: 0, mdepth: 0, dir: "changed", path: [.id], carried: .module, changed: true})) as $seeds |
# changed client code -> the backend route it calls (downstream; not followed further: other callers are not affected)
([ $F.client_calls[] | select(.route != null) | . as $c | route_rec($be; $c.route) as $r | select($r != null) |
   {from: "caller:\($c.client):\($c.caller)", node: rnode($be; $r), cite: $c.source} ]) as $p6 |

# ---- breadth-first walk with depth limit and cycle detection
({seen: ($seeds | map({key: .id, value: .}) | from_entries), frontier: $seeds, edges: [], cycles: [], truncated: []} |
 until((.frontier | length) == 0;
   . as $st |
   [ $st.frontier[] as $p | select($p.stop != true) | nbrs($p; ($p.x // mrec($p.id) // {fqcn: ($p.id | sub("^class:[^:]*:"; ""))}))[] | {p: $p, nb: .} ] as $exp |
   reduce $exp[] as $e ($st + {frontier: []};
     $e.nb.node as $t | $e.p as $p |
     (if $t.module != null and $t.module != $p.carried then $p.mdepth + 1 else $p.mdepth end) as $md |
     # once the change has flowed down (data, events, calls it makes) the path stays downstream
     (if $p.dir == "changed" or $e.nb.dir == "down" then $e.nb.dir else $p.dir end) as $dir |
     (if $e.nb.nfrom then {from: $t.id, to: $p.id} else {from: $p.id, to: $t.id} end) as $ed |
     .edges += [$ed + {type: $e.nb.type, cite: $e.nb.cite}] |
     if ($p.path | index($t.id)) != null then .cycles += [{path: ($p.path + [$t.id])}]
     elif .seen[$t.id] != null then
       (if .seen[$t.id].dir != $dir and .seen[$t.id].dir != "changed" then .seen[$t.id].dir = "both" else . end)
     elif $md > $depth then .truncated += [{node: $t.id, label: $t.label, module: $t.module, depth: $md}] | .tnodes[$t.id] = $t
     else ($t + {x: $e.nb.m, hops: ($p.hops + 1), mdepth: $md, dir: $dir, path: ($p.path + [$t.id]), carried: ($t.module // $p.carried)}) as $nn |
       .seen[$t.id] = $nn | .frontier += [$nn] end))) as $W |
# p6 targets (one hop, downstream, never expanded)
($W.seen + ([ $p6[] | .node as $t | select($W.seen[$t.id] == null) |
   {key: $t.id, value: ($t + {hops: 1, mdepth: (if $t.module != null and (direct_ids | index($t.module)) == null then 1 else 0 end), dir: "downstream",
                             path: [.from, $t.id], carried: $t.module})} ] | from_entries)) as $seen |
($seen | to_entries | map(.value) | sort_by(.id)) as $nodes |
([ $W.edges[], ($p6[] | {from: .from, to: .node.id, type: "calls", cite: .cite}) ] | unique_by("\(.from) \(.to) \(.type)")
 | to_entries | map(.value + {id: "e\(.key + 1)"})) as $edges |
def edge_between($a; $b): ([$edges[] | select((.from == $a and .to == $b) or (.from == $b and .to == $a))] | .[0]);
def path_edges($path): [range(1; $path | length) as $i | edge_between($path[$i - 1]; $path[$i]) | select(. != null)];
def lbl($id): ($seen[$id].label // $W.tnodes[$id].label // ($id | sub("^[a-z-]+:"; "")));
def dirword: if . == "up" then "upstream" elif . == "down" then "downstream" else . end;

# ---- modules
($F.direct_modules | map(. as $d | {id, name, critical, role: "direct", depth: 0, direction: "changed", why,
   paths: [], evidence: {class: "Verified", cites: [$F.spans[] | select(.kind != "route-line") | select(owners(.repo; .path) | index($d.id)) | "\(.repo):\(.path)\(if .to >= 1000000000 then "" else ":\(.from)" end)"] | unique}})) as $dm |
([ $nodes[] | .module as $mm | select($mm != null and (direct_ids | index($mm)) == null) ] | group_by(.module) | map(
   (min_by(.mdepth)) as $best | (map(.mdepth) | min) as $d | (map(.dir | dirword) | unique) as $dirs |
   ($M.modules[] | select(.id == $best.module)) as $m |
   (sort_by(.mdepth, (.path | length), .id) | .[0:3]) as $top |
   {id: $best.module, name: $m.name, critical: ($m.critical == true), role: "indirect", depth: $d,
    direction: (if ($dirs | length) > 1 or ($dirs | index("both")) then "both" else $dirs[0] end),
    why: [$top[] | "\(.dir | dirword) via " + ([.path[] | lbl(.)] | join(" → "))],
    paths: [$top[] | [path_edges(.path)[] | .id]],
    evidence: {class: "Verified", cites: ([$top[] | path_edges(.path)[] | .cite] | unique)}})) as $bfsm |
# v1 related modules the walk did not reach (e.g. modules.yaml table users without a mapped method) stay, as v1 found them
([ $F.related_modules[] | . as $r | select(($bfsm | map(.id) | index($r.id)) == null) |
   {id, name, critical, role: "indirect", depth: 1,
    direction: (if any(.why[]; startswith("calls ")) then "upstream" else "downstream" end), why, paths: [],
    evidence: {class: "Inferred", cites: ["modules.yaml"]}} ]) as $v1only |
($dm + ($bfsm + $v1only | sort_by(.depth, .id))) as $modules |
([$modules[].id]) as $affected |

# ---- changed and affected code
def coderec($x; $role; $n): {method: mlabel($x), kind: $x.ckind, repo: $x.repo, file: $x.file, cite: "\($x.repo):\($x.file):\($x.from)", lines: [$x.from, $x.to],
   module: (owners($x.repo; $x.file) | .[0]), role: $role, depth: ($n.mdepth // 0),
   reads: ($x.tables - [$x.writes[].table]), writes: $x.writes, uses: $x.uses, transaction: $x.transaction};
([ ($chm[] | coderec(.; "changed"; {})),
   ($nodes[] | select(.type == "method" and .changed != true) | . as $n | mrec(.id) | select(. != null) | coderec(.; "affected"; $n)) ]) as $code |

# ---- data flow of the changed code
([ $chm[] | . as $x | (mnode($x).id) as $mid |
   ( ($x.tables - [$x.writes[].table])[] | {from: "table:\(.)", to: $mid, table: ., op: "read", cite: "\($x.repo):\($x.file):\($x.from)",
       consumers: [], evidence: {class: "Verified", cites: ["\($x.repo):\($x.file):\($x.from)"]}} ),
   ( $x.writes[] | {from: $mid, to: "table:\(.table)", table, op: "write", via, cite: "\($x.repo):\($x.file):\(.lines[0])",
       consumers: (if .table == "?" then [] else table_users(.table) - direct_ids end),
       evidence: {class: (if .table == "?" then "Unknown" else "Verified" end), cites: ["\($x.repo):\($x.file):\(.lines | map(tostring) | join(","))"]}} ) ]
 | unique_by("\(.from) \(.to) \(.op)")) as $flow |

# ---- investigated, not affected
([ ($F.tables.read[] | .name as $t | table_users($t)[] | {id: ., checked: "uses table \($t)",
      reason: "\($t) is only read by the changed code; the change does not alter it"}),
   ($flow[] | select(.op == "write" and .table != "?") as $w | select(($F.tables.changed | map(.name) | index($w.table)) == null) | $w.consumers[] |
      {id: ., checked: "uses table \($w.table)",
       reason: "the changed code writes \($w.table) (\($w.cite)) but does not change its structure or meaning; its readers are not traced (seed --table \($w.table) if the values written change)"}),
   ($chm[] | .uses[] as $u | select($u.kind != "event") | ([$AM[] | select(.fqcn == $u.class) | owners(.repo; .file)[]] | unique)[] |
      {id: ., checked: "owns \($u.class | short)", reason: "\($u.class | short) is called by the changed code; its own code is unchanged"}) ]
 | map(select(. as $x | $affected | index($x.id) | not)) | group_by(.id)
 | map({id: .[0].id, checked: (map(.checked) | unique), reason: (map(.reason) | unique | join("; ")),
        evidence: {class: "Not affected", cites: []}})) as $notaff |

# ---- events emitted by the changed code
([ $chm[] | . as $x | .uses[] | select(.kind == "event") | . as $e |
   {event: $e.class, emitted_at: "\($x.repo):\($x.file):\($e.lines[0])",
    listeners: [ (($D[$x.repo].controllers.events // [])[] | select(.event == $e.class) | . as $ev | .listeners[] |
       {class: ., module: (cnode($x.repo; .) | .module), cite: "\($x.repo):\($ev.source)"}) ]} ]) as $events |

# ---- what cannot be known statically
([ ($D | to_entries[] | select(.value.controllers != null and (.value.controllers | has("classes") | not)) |
     {what: "services, jobs and events in \(.key)", why: "its _map has no services/events data (mapped before this feature); run /atreya:map \(.key)", where: "\(.key)/controllers.json"}),
   ($F.backend_routes[] | select((.callers | length) == 0) |
     {what: "callers of \(.key)", why: "no client in this workspace calls it; clients outside the workspace (old app versions, partners) cannot be ruled out", where: .source}),
   ($F.client_calls[] | select(.route == null) | {what: "target of \(.caller)", why: "the URL of this call cannot be resolved statically", where: .source}),
   ($F.spans[] | select(.kind != "route-line") as $s | ($D[$s.repo]["api-links"].unresolved // [])[] |
     select(.file == $s.path and .line >= $s.from and .line <= $s.to) | {what: "API call at \($s.repo):\(.file):\(.line)", why: .reason, where: "\($s.repo):\(.file):\(.line)"}),
   ($chm[] | . as $x | .writes[] | select(.table == "?") | {what: "table written at \($x.repo):\($x.file):\(.lines[0])", why: "the model of this save/update/delete cannot be resolved statically", where: "\($x.repo):\($x.file):\(.lines[0])"}),
   ($events[] | select((.listeners | length) == 0) | {what: "listeners of \(.event | short)", why: "none registered in EventServiceProvider $listen (auto-discovery, Event::listen or queued handlers are not mapped)", where: .emitted_at}),
   {what: "state shared outside routes and tables", why: "cache keys, sessions, queues, files and scheduled jobs are not mapped; check the changed methods by hand", where: "all changed code", generic: true} ]
 | unique_by(.what + " " + .where)) as $unknowns |

# ---- conflicting evidence
([ ($F.spans[] | select(.kind != "route-line") | owners(.repo; .path) as $o | select(($o | length) > 1) |
     {what: "\(.repo):\(.path) is owned by \($o | length) modules", sources: ($o | map("modules.yaml: \(.)")), effect: "every owner is treated as directly changed; fix modules.yaml"}),
   ($F.backend_routes[] | .key as $k | route_owners($be; $k) as $o |
     (select(($o | length) > 1) | {what: "\($k) is claimed by \($o | length) modules", sources: ($o | map("modules.yaml: \(.)")), effect: "the route's module is ambiguous"}),
     ( [ ($D | keys[]) as $c | links($c)[] | select(.route == $k and .module != null and (.module as $lm | $o | index($lm)) == null) | "\($c):\(.source) says \(.module)" ] |
       select(length > 0) | {what: "module of \($k) differs between modules.yaml (\($o | join(", "))) and api-links", sources: ., effect: "re-run /atreya:link-apis after /atreya:map --merge"})) ]
 | unique_by(.what)) as $conflicts |

# ---- traceability (requirement IDs and BRD rows whose citations point into the changed code)
([ $F.docs[] | .doc as $d | .cites as $c | .where[] | sub(" \\(route line only\\)$"; "") as $w |
   select($w | test("^([A-Z0-9]+(-[A-Z0-9]+)*-R[0-9]{2,}|BR-[0-9]{2,})$")) | {ref: $w, doc: $d, hits: $c} ] | unique_by(.ref + " " + .doc)) as $trace |

# ---- QA scope per affected module (web staging; app screens listed apart)
([ $modules[] | .id as $id |
   ([$F.backend_routes[] | select((route_owners($be; .key) | index($id)) != null) | .key] +
    [$nodes[] | select((.type == "route" or .type == "web-route") and .module == $id) | .label] | unique) as $routes |
   [$nodes[] | select((.type == "web-caller" or .type == "app-caller") and .module == $id)] as $mine |
   ([$F.backend_routes[] | select(.key as $k | $routes | index($k)) | .callers[]] ) as $rc |
   {id: $id, role: .role, routes: $routes,
    pages: ([$rc[] | select(kind(.client) == "blade") | .client as $c | .pages[] | "\($c):\(.)"] + [$mine[] | select(.type == "web-caller") | .repo as $c | .pages[] | "\($c):\(.)"] | unique),
    app_screens: ([$rc[] | select(kind(.client) == "flutter") | .pages[]] + [$mine[] | select(.type == "app-caller") | .pages[]] | unique)} ]) as $qamods |

$F + {
  schema: "atreya.impact/2", depth_limit: $depth,
  map_features: ($D | with_entries(select(.value.controllers != null) | .value = {uses: (.value.controllers | has("classes")), events: (.value.controllers | has("events"))})),
  modules: $modules, not_affected: $notaff,
  graph: {nodes: ([$nodes[] | {id, type, label, module, cite, depth: .mdepth, direction: (if .dir == "changed" then "changed" else (.dir | dirword) end), changed: (.changed == true)}] +
                  [$W.truncated[] | {id: .node, type: "truncated", label, module, cite: null, depth, direction: "beyond depth limit", changed: false}] | unique_by(.id)),
          edges: $edges},
  code: $code, events: $events, data_flow: $flow,
  unknowns: $unknowns, conflicts: $conflicts, cycles: ($W.cycles | unique_by(.path)), truncated: ($W.truncated | unique_by(.node)),
  traceability: $trace,
  qa_scope: {modules: $qamods, existing: [$trace[] | select(.ref | test("-R[0-9]+$")) | {ref, kind: "PRD acceptance criteria", source: .doc}]}
}
