# impact-view.jq: the one view both impact.md and impact-report.html are
# rendered from (included by impact-md.jq and impact-html.jq), so the two
# reports cannot disagree. Input: impact-facts.json with "analysis" merged.
def rank: {"Critical": 4, "High": 3, "Medium": 2, "Low": 1}[.] // 0;
def conf_of: {"Verified": "High", "Inferred": "Medium"}[.] // "Low";
def short: split("\\") | last;
def view:
  . as $F | ($F.analysis // {}) as $A |
  [$F.modules[] | select(.role == "direct") | .id] as $direct |
  # ---- risks: script records + analysis records (add or raise only)
  ([ ($F.risks[] | . + {source: "script"}),
     (($A.risks // [])[] | . + {source: "analysis", confidence: (.evidence.class | conf_of), modules: (.modules // [])}) ]
   | sort_by(-(.level | rank), .source != "script", .id)) as $risks |
  ($F.risk_overall.level) as $slevel |
  (if $slevel == "TBD" then "TBD" else ([$risks[].level | rank] | max // 1) as $r | {"4": "Critical", "3": "High", "2": "Medium", "1": "Low"}["\($r)"] end) as $level |
  ([$risks[] | select(.source == "analysis" and .level == $level and ($level | rank) > ($slevel | rank)) | .id]) as $raised |
  (if ($raised | length) > 0 then ([$risks[] | select(.id as $i | $raised | index($i)) | .confidence] | if index("Low") then "Low" elif index("Medium") then "Medium" else "High" end)
   else $F.risk_overall.confidence end) as $conf |
  # ---- modules: facts + analysis notes + what touches each
  ([ ($F.modules[] | . + {source: "facts"}),
     (($A.added_modules // [])[] | {id, name: .id, critical: false, role: "indirect", depth: null, direction: "found by analysis",
                                    why: [.why], paths: [], evidence: .evidence, source: "analysis"}) ]) as $mods0 |
  ([$F.graph.nodes[] | {key: .id, value: .module}] | from_entries) as $nm |
  ([$F.graph.edges[] | {key: .id, value: .}] | from_entries) as $em |
  ([ $mods0[] | select(.role == "indirect") | . as $m |
     ([.paths[0] // [] | .[] | $em[.] | select(. != null) | {from: $nm[.from], to: $nm[.to], type} |
        select(.from != null and .to != null and .from != .to)]) as $pe |
     if ($pe | length) > 0 then $pe[]
     elif ($direct | length) > 0 then {from: $direct[0], to: $m.id, type: (if $m.source == "analysis" then "analysis" else "shared data" end)}
     else empty end ] | group_by(.from + " " + .to) | map({from: .[0].from, to: .[0].to, types: (map(.type) | unique)})) as $medges |
  {ticket: $F.ticket, date: $F.review.date, status: "Draft", reviewer: ($F.review.reviewer // "TBD"),
   sha: $F.facts_sha256, commits: $F.commits, map_behind: $F.map_behind, depth_limit: $F.depth_limit,
   input: ($A.input // {}), requirement: ($A.requirement // {}), summary: ($A.summary // {}),
   title: ($A.input.title // $F.ticket),
   changed_modules: $direct,
   counts: {direct: ($direct | length), indirect: ([$mods0[] | select(.role == "indirect")] | length), not_affected: (($F.not_affected | length) + (($A.not_affected // []) | length)),
            unknowns: ($F.unknowns | length), conflicts: ($F.conflicts | length), questions: (($A.open_questions // []) | length)},
   risk: {level: $level, confidence: $conf, script_level: $slevel, raised_by: $raised, rules: $F.risk_overall.rules,
          why: $F.risk_overall.confidence_why, v1_level: $F.risk.level},
   risks: $risks,
   modules: [ $mods0[] | . as $m | .id as $id |
     ([($F.qa_scope.modules // [])[] | select(.id == $id)] | .[0] // {}) as $qs |
     . + {notes: ($A.module_notes[$id] // null),
          routes: ($qs.routes // []), pages: ($qs.pages // []), app_screens: ($qs.app_screens // []),
          code: [$F.code[] | select(.module == $id)],
          tables: ([$F.code[] | select(.module == $id) | (.reads[] | {table: ., op: "read"}), (.writes[] | {table, op: "write"})] | unique),
          risk_ids: [$risks[] | select((.modules | index($id)) or ((.modules | length) == 0 and ($direct | index($id)))) | .id],
          scenario_ids: [($A.qa_scenarios // [])[] | select(.module == $id) | .id]} ],
   module_edges: $medges,
   qa_groups: ([ ($mods0[] | {id, role}), (($A.qa_scenarios // [])[] | select(.module != null and .module != "") | {id: .module, role: "not affected"}) ]
     | unique_by(.id) as $u | [$mods0[].id] as $order | ($u | sort_by((.id as $i | $order | index($i)) // 999, .id)) | map(. as $g |
       ([($F.qa_scope.modules // [])[] | select(.id == $g.id)] | .[0] // {}) as $qs |
       {id, role: (if ([$mods0[].id] | index($g.id)) then .role else "not affected" end),
        pages: ($qs.pages // []), app_screens: ($qs.app_screens // []),
        scenario_ids: [($A.qa_scenarios // [])[] | select(.module == $g.id) | .id]})
     | map(select((.scenario_ids | length) + (.pages | length) + (.app_screens | length) > 0))),
   not_affected: ([$F.not_affected[] | . + {source: "facts"}] + [($A.not_affected // [])[] | {id, checked: [], reason, evidence, source: "analysis"}]),
   workflow: (($A.workflow // []) | sort_by(.step)),
   data_flow: $F.data_flow, data_fields: ($A.data_fields // []), data_consistency: ($A.data_consistency // []),
   data_risks: [$risks[] | select(.rule | test("^(MONEY|DATA)-"))],
   qa_scenarios: ($A.qa_scenarios // []), qa_existing: $F.qa_scope.existing, qa_v1: $F.qa,
   traceability: ([$F.traceability[] | {ref, doc, hits, note: null}] + [($A.traceability // [])[] | {ref, doc: null, hits: [], note}]),
   docs: $F.docs, unknowns: $F.unknowns, conflicts: $F.conflicts, cycles: $F.cycles, truncated: $F.truncated,
   open_questions: ($A.open_questions // []), assumptions: ($A.assumptions // []), actions: ($A.actions // []),
   backend_routes: $F.backend_routes, web_routes: $F.web_routes, client_calls: $F.client_calls, screens: $F.screens,
   tables: $F.tables, external_systems: $F.external_systems, events: $F.events, code: $F.code}
;
