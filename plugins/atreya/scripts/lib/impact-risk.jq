# impact-risk.jq: rule-based risk records (references/impact-risk-rules.md).
# Run by scripts/impact-facts.sh only, on the facts after impact-graph.jq:
#   jq --slurpfile Sg signals.json -f impact-risk.jq facts.json
# Every record names its rule, level, reason, consequence and evidence, so each
# level can be explained. The v1 "risk" key (High/Medium/Low/TBD) is left as is.
$Sg[0] as $S | . as $F |
def lc: ascii_downcase;
def money_t: . as $t | any(($S.money.tables // [])[]; . as $p | $t | lc | contains($p | lc));
def sec_w: . as $s | [($S.security.words // [])[] | select(. as $p | $s | lc | contains($p | lc))];
def rec($rule; $level; $reason; $cons; $class; $cites):
  {rule: $rule, level: $level, reason: $reason, consequence: $cons, evidence: {class: $class, cites: ($cites | unique)},
   confidence: ({"Verified": "High", "Inferred": "Medium"}[$class] // "Low"), modules: []};
def rank: {"Critical": 4, "High": 3, "Medium": 2, "Low": 1}[.] // 0;
[$F.modules[] | select(.role == "direct")] as $dir | [$F.modules[] | select(.role == "indirect")] as $ind |
[$F.code[] | select(.role == "changed")] as $chg | [$dir[].id] as $dids | [$F.modules[].id] as $all |

([
  # ---- money
  ($F.external_systems[] | select(.system as $s | ($S.money.externals // []) | index($s)) |
    rec("MONEY-01"; "Critical"; "\(.system) code is inside the changed code"; "A fault can charge, refund or mandate the wrong amount or the wrong account."; "Verified"; [.where]) | .modules = $dids),
  ($F.tables.changed[] | select(.name | money_t) |
    rec("MONEY-02"; "Critical"; "changed table \(.name) holds money data (its name matches a money pattern)"; "A structure or meaning change can corrupt or misstate payment and transaction records."; "Inferred"; []) + {modules: .modules}),
  ($chg[] | . as $m | .writes[] | select(.table != "?" and (.table | money_t)) |
    rec("MONEY-02"; "Critical"; "\($m.method) writes \(.table), a money table (its name matches a money pattern)"; "Wrong or partial writes can lose, duplicate or misstate money records."; "Inferred"; ["\($m.repo):\($m.file):\(.lines[0])"]) | .modules = [$m.module // empty]),
  ($chg[] | . as $m | .reads[] | select(money_t) |
    rec("MONEY-03"; "High"; "\($m.method) reads \(.), a money table (its name matches a money pattern)"; "Amounts or statuses shown or used downstream can be wrong."; "Inferred"; [$m.cite]) | .modules = [$m.module // empty]),
  ($ind[] | select(.id as $i | ($S.money.modules // []) | index($i)) |
    rec("MONEY-03"; "High"; "money module \(.id) is indirectly affected (\(.why[0]))"; "Payments or settlements can fail or be misstated."; "Verified"; .evidence.cites) + {modules: [.id]}),
  # ---- business criticality
  ($dir[] | select(.critical) | rec("CRIT-01"; "High"; "critical module \(.id) is directly changed"; "A core business flow can break for every user of the module."; "Verified"; .evidence.cites) + {modules: [.id]}),
  ($ind[] | select(.critical) | rec("CRIT-02"; "Medium"; "critical module \(.id) is indirectly affected (\(.why[0]))"; "A core business flow can change without its own code changing."; .evidence.class; .evidence.cites) + {modules: [.id]}),
  # ---- security
  ($F.backend_routes[] | . as $r | ([.key, .controller] + (.middleware // []) | map(sec_w[]) | unique) as $w | select($w | length > 0) |
    rec("SEC-01"; "High"; "changed route \(.key) (\(.controller)) is security-sensitive (matches: \($w | join(", ")))"; "Users can be locked out, or access can be granted or kept wrongly."; "Inferred"; [.source]) | .modules = $dids),
  ($chg[] | . as $m | (.method | sec_w) as $w | select($w | length > 0) |
    rec("SEC-01"; "High"; "changed method \(.method) is security-sensitive (matches: \($w | join(", ")))"; "Users can be locked out, or access can be granted or kept wrongly."; "Inferred"; [.cite]) + {modules: [.module // empty]}),
  # ---- data integrity
  ($F.tables.changed[] | select((.modules | length) >= 3) |
    rec("DATA-01"; "High"; "changed table \(.name) is used by \(.modules | length) modules"; "Every module reading the table can show or store wrong data."; "Inferred"; ["modules.yaml"]) + {modules: .modules}),
  ($F.tables.changed[] | select((.modules | length) == 2) |
    rec("DATA-02"; "Medium"; "changed table \(.name) is shared by 2 modules (\(.modules | join(", ")))"; "The other module can show or store wrong data."; "Inferred"; ["modules.yaml"]) + {modules: .modules}),
  ($chg[] | . as $m | ([.writes[] | select(.table != "?") | .table] | unique) as $t | select(($t | length) >= 2 and ($m.transaction | not)) |
    rec("DATA-03"; (if any($t[]; money_t) then "High" else "Medium" end);
        "\($m.method) writes \($t | length) tables (\($t | join(", "))) without a DB transaction";
        "A failure between the writes leaves the tables inconsistent (one written, the other not)."; "Inferred";
        [$m.writes[] | "\($m.repo):\($m.file):\(.lines[0])"]) | .modules = [$m.module // empty]),
  ($F.data_flow[] | select(.op == "write" and (.consumers | length) > 0) |
    rec("DATA-04"; "Low"; "the changed code writes \(.table), which \(.consumers | length) other module(s) read (\(.consumers[0:5] | join(", "))\(if (.consumers | length) > 5 then ", …" else "" end))";
        "If the values written change, these modules see different data."; "Inferred"; [.cite]) + {modules: .consumers}),
  # ---- dependency count
  (if ($dir | length) >= 4 then rec("DEP-01"; "High"; "\($dir | length) modules are directly changed"; "Many teams' flows change at once; regressions are likely to be missed."; "Verified"; [$dir[].evidence.cites[]]) | .modules = (if .rule == "DEP-03" then $all else $dids end) else empty end),
  (if ($dir | length) >= 2 and ($dir | length) <= 3 then rec("DEP-02"; "Medium"; "\($dir | length) modules are directly changed (\([$dir[].id] | join(", ")))"; "Changes in several modules must be released and tested together."; "Verified"; [$dir[].evidence.cites[]]) | .modules = (if .rule == "DEP-03" then $all else $dids end) else empty end),
  (if ($dir | length) + ($ind | length) >= 6 then rec("DEP-03"; "High"; "\(($dir | length) + ($ind | length)) modules are affected (\($dir | length) direct, \($ind | length) indirect)"; "The regression surface is wide."; "Verified"; []) | .modules = (if .rule == "DEP-03" then $all else $dids end)
   elif ($ind | length) >= 3 then rec("DEP-03"; "Medium"; "\($ind | length) modules are indirectly affected"; "Modules that did not change can behave differently."; "Verified"; []) | .modules = (if .rule == "DEP-03" then $all else $dids end) else empty end),
  # ---- callers and external systems (v1)
  ($F.risk.medium[] | capture("^route (?<k>.+) is called by web and app$") | .k as $k | $F.backend_routes[] | select(.key == $k) |
     rec("CALL-01"; "Medium"; "changed route \(.key) is called by both the web app and the mobile app"; "Both clients must be tested; the app may not be updatable at the same time."; "Verified"; [.callers[].source]) | .modules = $dids),
  ($F.external_systems | map(.system) | unique[] as $s | select((($S.money.externals // []) | index($s)) == null) |
     rec("EXT-01"; "Medium"; "the changed code uses external system \($s)"; "The third party's behaviour, limits or outages affect this flow; it can only be tested where it is configured."; "Verified";
         [$F.external_systems[] | select(.system == $s) | .where]) | .modules = $dids)
] | sort_by(-(.level | rank), .rule, .reason) | to_entries | map({id: "RS-\(.key + 1 | tostring | if length < 2 then "0" + . else . end)"} + .value)) as $risks |

([$F.unknowns[] | select(.generic != true)] | length) as $nunk |
(if ($F.modules | length) == 0 then "TBD" elif ($risks | length) == 0 then "Low" else $risks[0].level end) as $level |
([$risks[] | select(.level == $level)]) as $top |
(if ($F.conflicts | length) > 0 then "Low"
 elif ($top | length) == 0 then (if $nunk > 0 then "Medium" else "High" end)
 elif any($top[]; .confidence == "Low") then "Low"
 elif any($top[]; .confidence == "Medium") or $nunk > 0 then "Medium" else "High" end) as $conf |
$F + {risks: $risks,
      risk_overall: {level: $level, rules: ([$top[].rule] | unique), confidence: $conf,
                     confidence_why: ([(if ($F.conflicts | length) > 0 then "\($F.conflicts | length) conflicting evidence item(s)" else empty end),
                                       (if any($top[]; .evidence.class == "Inferred") then "the deciding risk is inferred from names or rules" else empty end),
                                       (if $nunk > 0 then "\($nunk) unknown link(s) in the changed area" else empty end)])}}
