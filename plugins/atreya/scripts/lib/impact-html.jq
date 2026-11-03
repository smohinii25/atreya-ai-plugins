# impact-html.jq: the parts of impact-report.html, from the same view as impact.md.
#   jq -r -L scripts/lib --arg part head|body|data -f impact-html.jq impact-facts.json
# EVERY value from the facts or the analysis passes h (@html escaping), also in
# attributes. The data part is JSON for the dependency map, embedded in a
# <script type="application/json"> with < > & U+2028 U+2029 written as \uXXXX.
# No external URL, no inline event handler, no raw HTML from data.
include "impact-view";
def h: tostring | @html;
def evcls: gsub(" "; "-");
def ev($e): if $e == null then "" else
  "<span class=\"ev ev-\($e.class | evcls | h)\" title=\"\(($e.note // "") | h)\">\($e.class | h)</span>" +
  (if (($e.cites // []) | length) > 0 then " " + ($e.cites | map("<code>\(h)</code>") | join(" ")) else "" end) end;
def stmt: if type == "object" then "\(.text | h) \(ev(.evidence))" else h end;
def ul($x; f): if ($x | length) == 0 then "<p class=\"muted\">None.</p>" else "<ul class=\"plain\">" + ($x | map("<li>" + (. | f) + "</li>") | join("")) + "</ul>" end;
def lvl($l): "<span class=\"badge lvl-\($l | h)\">\($l | h)</span>";
def dirw: if . == null then "" else h end;
def table($head; $rows): if ($rows | length) == 0 then "<p class=\"muted\">None.</p>" else
  "<div class=\"tablewrap\"><table><thead><tr>" + ($head | map("<th>\(h)</th>") | join("")) + "</tr></thead><tbody>" + ($rows | join("")) + "</tbody></table></div>" end;
def nz: if . == null or . == "" then "–" else . end;
def jsonsafe: tojson | gsub("<"; "\\u003c") | gsub(">"; "\\u003e") | gsub("&"; "\\u0026") | gsub(" "; "\\u2028") | gsub(" "; "\\u2029");

view as $V |
if $part == "head" then "<title>\($V.title | h) — impact analysis (Draft)</title>"
elif $part == "data" then
  "<script type=\"application/json\" id=\"atreya-data\">" +
  ({depthLimit: $V.depth_limit,
    modules: [$V.modules[] | . as $m | {id, name, role, depth, direction, critical,
               why: (.why[0] // ""), risk: ([$V.risks[] | select(.id as $i | $m.risk_ids | index($i)) | .level] | .[0])}],
    edges: $V.module_edges,
    truncated: [$V.truncated[] | select(.module != null) | {module, label, depth}] | unique_by(.module)} | jsonsafe) +
  "</script>"
else
[
"<header class=\"top\"><h1>\($V.title | h)</h1>",
"<div class=\"meta\"><span class=\"badge draft\" data-status=\"Draft\">Draft</span><span>Ticket <code>\($V.ticket | h)</code></span>",
"<span>\(if $V.input.source == "zoho" then "Zoho Sprints \($V.input.id | h)" else "Free-text request" end)</span><span>Generated \($V.date | h)</span>",
"<span>Reviewer \($V.reviewer | h)</span><span>Commits: \([$V.commits | to_entries[] | "\(.key | h) <code>\(.value[0:10] | h)</code>"] | join(", "))</span></div>",
"<div class=\"legend\">Evidence: <span class=\"ev ev-Verified\">Verified</span> code at the stamped commit · <span class=\"ev ev-Inferred\">Inferred</span> derived from verified facts · <span class=\"ev ev-Assumption\">Assumption</span> not proven · <span class=\"ev ev-Unknown\">Unknown</span> cannot be known statically · <span class=\"ev ev-Not-affected\">Not affected</span> checked and cleared</div>",
"</header>",
"<nav class=\"toc\"><a href=\"#summary\">Summary</a><a href=\"#map\">Dependency map</a><a href=\"#workflow\">Workflow</a><a href=\"#modules\">Modules</a><a href=\"#data\">Data flow</a><a href=\"#risks\">Risks</a><a href=\"#qa\">QA scope</a><a href=\"#evidence\">Evidence</a><a href=\"#questions\">Open questions</a><a href=\"#review\">Review</a></nav>",
"<main>",

# ---------------------------------------------------------------- executive summary
"<section id=\"summary\"><h2>Executive summary</h2>",
"<p class=\"lead\">\(($V.summary.headline // "") | h)</p>",
"<blockquote>\(($V.input.text // "") | h)</blockquote>",
"<div class=\"cards\">",
"<div class=\"card\"><div class=\"k\">Changed module</div><div class=\"v\">\(if ($V.changed_modules | length) == 0 then "–" else ($V.changed_modules | map(h) | join(", ")) end)</div></div>",
"<div class=\"card\"><div class=\"k\">Direct modules</div><div class=\"v\" data-count=\"direct\">\($V.counts.direct)</div></div>",
"<div class=\"card\"><div class=\"k\">Indirect modules</div><div class=\"v\" data-count=\"indirect\">\($V.counts.indirect)</div></div>",
"<div class=\"card\"><div class=\"k\">Overall risk</div><div class=\"v\" data-risk-level=\"\($V.risk.level | h)\">\(lvl($V.risk.level))</div><div class=\"muted\">confidence \($V.risk.confidence | h)</div></div>",
"<div class=\"card\"><div class=\"k\">Open questions</div><div class=\"v\" data-count=\"questions\">\($V.counts.questions)</div><div class=\"muted\">\($V.counts.unknowns) unknowns · \($V.counts.conflicts) conflicts</div></div>",
"</div>",
"<h3>Key business consequences</h3>", ul($V.summary.consequences // []; stmt),
"<details class=\"tech\"><summary>Requirement understanding</summary><div class=\"body\">",
"<h3>Current behaviour</h3>", ul($V.requirement.current // []; stmt),
"<h3>Proposed behaviour</h3>", ul($V.requirement.proposed // []; stmt),
"<h3>Business objective</h3>", (if $V.requirement.objective then "<p>\($V.requirement.objective | stmt)</p>" else "<p class=\"muted\">Not stated (see open questions).</p>" end),
"<h3>Ambiguities</h3>", ul($V.requirement.ambiguities // []; "\(.text | h) → <a href=\"#q-\(.question | h)\">\(.question | h)</a>"),
"<h3>Missing requirements</h3>", ul($V.requirement.missing // []; "\(.text | h) → <a href=\"#q-\(.question | h)\">\(.question | h)</a>"),
"</div></details>",
"<details class=\"tech\"><summary>How the overall risk was decided</summary><div class=\"body\"><p>Script rules: \(lvl($V.risk.script_level)) \(if ($V.risk.rules | length) > 0 then "(" + ($V.risk.rules | map(h) | join(", ")) + ")" else "" end)\(if ($V.risk.raised_by | length) > 0 then "; raised by the analysis: " + ($V.risk.raised_by | map("<a href=\"#risk-\(h)\">\(h)</a>") | join(", ")) else "" end). v1 rule level: \($V.risk.v1_level | h).</p>",
ul($V.risk.why; h), "</div></details>",
"</section>",

# ---------------------------------------------------------------- dependency map
"<section id=\"map\"><h2>Dependency map</h2>",
"<p class=\"muted\">The changed module is in the middle. Upstream modules (left) call into the changed code; downstream modules (right) are called by it or use data it changes. Depth = module hops from the change (limit \($V.depth_limit)). Click a module to open its details.</p>",
"<div class=\"controls\"><input type=\"search\" id=\"q\" placeholder=\"Search modules, risks, scenarios…\" aria-label=\"Search\">",
"<label><input type=\"checkbox\" data-filter=\"role:direct\" checked> direct</label><label><input type=\"checkbox\" data-filter=\"role:indirect\" checked> indirect</label>",
"<label><input type=\"checkbox\" data-filter=\"dir:upstream\" checked> upstream</label><label><input type=\"checkbox\" data-filter=\"dir:downstream\" checked> downstream</label>",
"<label><input type=\"checkbox\" data-filter=\"dir:both\" checked> both</label><label><input type=\"checkbox\" data-filter=\"dir:other\" checked> other</label>",
"<button type=\"button\" id=\"expand-all\">Expand all</button></div>",
"<div id=\"mapbox\"></div>",
"<ul class=\"plain maplist\">" + ([$V.modules[] | "<li data-module=\"\(.id | h)\" data-name=\"\(.name | h)\" data-role=\"\(.role | h)\" data-direction=\"\(.direction | dirw)\"><a href=\"#mod-\(.id | h)\" data-goto=\"mod-\(.id | h)\"><b>\(.id | h)</b></a> <span class=\"role role-\(.role | h)\">\(.role | h)</span> \(if .role == "indirect" then "<span class=\"dir-\(.direction | dirw)\">\(.direction | dirw)</span>, depth \(.depth | nz | h)" else "" end) — \(.why | map(h) | join("; "))</li>"] | join("")) + "</ul>",
"</section>",

# ---------------------------------------------------------------- workflow
"<section id=\"workflow\"><h2>End-to-end workflow</h2>",
(if ($V.workflow | length) == 0 then "<p class=\"muted\">No workflow described (see open questions).</p>" else
 "<ol class=\"steps\">" + ($V.workflow | map(
   "<li data-search id=\"step-\(.step | h)\"><b>Step \(.step | h)</b> · \(.actor | h) · \((.module // "–") | h)\(if .screen or .route then " · " + ([.screen, .route] | map(select(. != null and . != "")) | map("<code>\(h)</code>") | join(" ")) else "" end)" +
   "<div class=\"ba\"><div><div class=\"h\">Before</div>\(.before | h)</div><div><div class=\"h\">After</div>\(.after | h)</div></div>" +
   "<div class=\"fail\"><b>If this step fails:</b> \(.on_failure | h)</div><div>\(ev(.evidence))</div></li>") | join("")) + "</ol>" end),
"</section>",

# ---------------------------------------------------------------- modules
"<section id=\"modules\"><h2>Modules</h2>",
([$V.modules[] | . as $m |
  "<details class=\"module\" id=\"mod-\(.id | h)\" data-module=\"\(.id | h)\" data-name=\"\(.name | h)\" data-role=\"\(.role | h)\" data-direction=\"\(.direction | dirw)\">" +
  "<summary><b>\(.id | h)</b> <span class=\"muted\">\(.name | h)</span> <span class=\"role role-\(.role | h)\">\(.role | h)</span>" +
  (if .role == "indirect" then " <span class=\"dir-\(.direction | dirw)\">\(.direction | dirw)</span> <span class=\"muted\">depth \(.depth | nz | h)</span>" else "" end) +
  (if .critical then " <span class=\"badge lvl-High\">critical</span>" else "" end) +
  ([$V.risks[] | select(.id as $i | $m.risk_ids | index($i))] | if length > 0 then " " + lvl(.[0].level) else "" end) + "</summary><div class=\"body\">" +
  (if .notes then "<p>\((.notes.description // "") | h)</p><p><b>Why affected:</b> \((.notes.why_affected // "") | h)</p>" + "<b>Functional impact</b>" + ul(.notes.functional_impact // []; stmt)
   else "<p class=\"muted\">No description written for this module.</p>" end) +
  "<p><b>How it is connected:</b></p>" + ul(.why; h) + "<p>\(ev(.evidence))</p>" +
  "<details class=\"tech\"><summary>Technical details</summary><div class=\"body\">" +
  "<h3>Screens and pages</h3>" + ul(.pages + .app_screens; h) +
  "<h3>APIs</h3>" + ul(.routes; "<code>\(h)</code>") +
  "<h3>Code</h3>" + table(["Role", "Method", "Kind", "Reads", "Writes", "Uses", "Source"];
     [.code[] | "<tr><td>\(.role | h)</td><td>\(.method | h)</td><td>\(.kind | h)</td><td>\(.reads | map(h) | join(", "))</td><td>\([.writes[].table] | unique | map(h) | join(", "))</td><td>\([.uses[].class | short] | map(h) | join(", "))</td><td><code>\(.cite | h)</code></td></tr>"]) +
  "<h3>Data</h3>" + ul(.tables; "\(.op | h) <code>\(.table | h)</code>") +
  "<h3>Risks</h3>" + ul(.risk_ids; "<a href=\"#risk-\(h)\">\(h)</a>") +
  "<h3>QA scenarios</h3>" + ul(.scenario_ids; "<a href=\"#qa-\(h)\">\(h)</a>") +
  "</div></details></div></details>"] | join("")),
"<details class=\"tech\"><summary>Investigated, not affected (\($V.not_affected | length))</summary><div class=\"body\">",
ul($V.not_affected; "<b>\(.id | h)</b>: \(.reason | h) \(ev(.evidence))"), "</div></details>",
"</section>",

# ---------------------------------------------------------------- data
"<section id=\"data\"><h2>Data-flow impact</h2>",
table(["Operation", "Table", "Where", "Other modules reading it", "Evidence"];
  [$V.data_flow[] | "<tr data-search><td>\(.op | h)</td><td><code>\(.table | h)</code></td><td><code>\(.cite | h)</code></td><td>\(if (.consumers | length) == 0 then "–" else "\(.consumers | length): " + (.consumers[0:8] | map(h) | join(", ")) + (if (.consumers | length) > 8 then ", …" else "" end) end)</td><td>\(ev(.evidence))</td></tr>"]),
"<h3>Data fields and calculations</h3>",
ul($V.data_fields; "<code>\((.table // "?") | h).\((.field // "?") | h)</code>: \(.change | h)\(if .calculation then "; calculation: \(.calculation | h)" else "" end) \(ev(.evidence))"),
"<h3>Data-consistency and financial risks</h3>",
ul([($V.data_risks[] | "<a href=\"#risk-\(.id | h)\">\(.id | h)</a> \(lvl(.level)) \(.reason | h). \(.consequence | h)"),
    ($V.data_consistency[] | "\(.text | h). \((.consequence // "") | h) \(if .risk then "(<a href=\"#risk-\(.risk | h)\">\(.risk | h)</a>)" else "" end) \(ev(.evidence))")]; .),
"<details class=\"tech\"><summary>Tables changed and read</summary><div class=\"body\">",
"<h3>Changed</h3>", ul($V.tables.changed; "<code>\(.name | h)</code> used by \(.modules | map(h) | join(", ") | nz)"),
"<h3>Read by the changed routes</h3>", ul($V.tables.read; "<code>\(.name | h)</code> (\(.modules) modules)"),
"<h3>External systems</h3>", ul($V.external_systems; "\(.system | h): <code>\(.where | h)</code>"),
"<h3>Events</h3>", ul($V.events; "\(.event | short | h) at <code>\(.emitted_at | h)</code> → \(if (.listeners | length) == 0 then "no mapped listener" else ([.listeners[] | "\(.class | short | h) (\((.module // "no module") | h))"] | join(", ")) end)"),
"</div></details>",
"</section>",

# ---------------------------------------------------------------- risks
"<section id=\"risks\"><h2>Risks</h2>",
"<p>Overall \(lvl($V.risk.level)) (confidence \($V.risk.confidence | h)). Every level comes from a rule in <code>references/impact-risk-rules.md</code>.</p>",
"<div class=\"controls\"><label>Level <select id=\"level-filter\"><option value=\"\">all</option><option>Critical</option><option>High</option><option>Medium</option><option>Low</option></select></label></div>",
table(["ID", "Level", "Rule", "Reason", "Consequence", "Evidence", "Confidence", "Source"];
  [$V.risks[] | "<tr id=\"risk-\(.id | h)\" data-level=\"\(.level | h)\"><td><b>\(.id | h)</b></td><td>\(lvl(.level))</td><td>\(.rule | h)</td><td>\(.reason | h)</td><td>\(.consequence | h)</td><td>\(ev(.evidence))</td><td>\(.confidence | h)</td><td>\(.source | h)</td></tr>"]),
"</section>",

# ---------------------------------------------------------------- QA
"<section id=\"qa\"><h2>QA regression scope</h2>",
"<p class=\"muted\">Web staging only (references/qa-scope-rules.md). Nothing below was executed by this analysis; status shows \"Not run\" unless a QA report is cited.</p>",
"<p>Sanity: \($V.qa_v1.sanity | map(h) | join(", ") | nz) · Regression: \($V.qa_v1.regression | map(h) | join(", ") | nz)</p>",
ul($V.qa_v1.not_covered; "Not covered by QA: " + h),
"<h3>By module</h3>",
([$V.qa_groups[] | . as $m |
  "<details data-search><summary><b>\(.id | h)</b> <span class=\"muted\">\(.role | h) · \(.scenario_ids | length) scenario(s) · \(.pages | length) page(s) · \(.app_screens | length) app screen(s)</span></summary><div class=\"body\">" +
  "<p>Pages: \(.pages | map(h) | join(", ") | nz)<br>App screens (developer to test): \(.app_screens | map(h) | join(", ") | nz)</p>" +
  table(["ID", "Type", "Origin", "Scenario", "Expected", "Trace", "Status"];
    [$V.qa_scenarios[] | select(.module == $m.id) | "<tr><td>\(.id | h)</td><td>\(.type | h)</td><td>\(.origin | h)</td><td>\(.title | h)</td><td>\(.expected | h)</td><td>\((.trace // []) | map(h) | join(", ") | nz)</td><td>\(.status | h)</td></tr>"]) +
  "</div></details>"] | join("")),
"<h3>All scenarios</h3>",
table(["ID", "Module", "Workflow step", "Type", "Origin", "Scenario", "Expected", "Trace", "Status"];
  [$V.qa_scenarios[] | "<tr id=\"qa-\(.id | h)\" data-search><td><b>\(.id | h)</b></td><td>\((.module // "–") | h)</td><td>\(if .step then "<a href=\"#step-\(.step | h)\">\(.step | h)</a>" else "–" end)</td><td>\(.type | h)</td><td>\(.origin | h)</td><td>\(.title | h)</td><td>\(.expected | h)</td><td>\((.trace // []) | map(h) | join(", ") | nz)</td><td>\(.status | h)</td></tr>"]),
"<h3>Existing tests and acceptance criteria</h3>", ul($V.qa_existing; "\(.ref | h): \(.kind | h) (<code>\(.source | h)</code>)"),
"</section>",

# ---------------------------------------------------------------- evidence
"<section id=\"evidence\"><h2>Evidence and traceability</h2>",
"<h3>Requirements and docs that cite the changed code</h3>", ul($V.traceability; "<b>\(.ref | h)</b>\(if .doc then " (\(.doc | h))" else "" end)\(if .note then ": \(.note | h)" else "" end)"),
"<h3>Docs and diagrams to update</h3>", ul($V.docs; "\(.doc | h): \(.where | map(h) | join(", "))"),
"<h3>Unknowns</h3>", ul($V.unknowns; "<span class=\"ev ev-Unknown\">Unknown</span> \(.what | h): \(.why | h) <code>\(.where | h)</code>"),
"<h3>Conflicting evidence</h3>", ul($V.conflicts; "\(.what | h): \(.effect | h) (\(.sources | map(h) | join("; ")))"),
"<details class=\"tech\"><summary>Changed routes, callers and code</summary><div class=\"body\">",
"<h3>Backend routes changed</h3>",
ul($V.backend_routes; "<code>\(.key | h)</code> → \(.controller | h) <code>\(.source | h)</code>" + ul(.callers; "called by \(.client | h) \(.caller | h) <code>\(.source | h)</code>; pages: \(.pages | map(h) | join(", ") | nz)")),
"<h3>Web routes changed</h3>", ul($V.web_routes; "<code>\(.repo | h) \(.key | h)</code> → \(.controller | h) <code>\(.source | h)</code>"),
"<h3>API calls from changed client code</h3>", ul($V.client_calls; "\(.client | h) \(.caller | h) → <code>\((.route // "unresolved") | h)</code> <code>\(.source | h)</code>"),
"<h3>Changed and affected code</h3>",
table(["Role", "Method", "Kind", "Module", "Transaction", "Source"]; [$V.code[] | "<tr><td>\(.role | h)</td><td>\(.method | h)</td><td>\(.kind | h)</td><td>\((.module // "–") | h)</td><td>\(if .transaction then "yes" else "no" end)</td><td><code>\(.cite | h)</code></td></tr>"]),
"<h3>Cycles</h3>", ul($V.cycles; .path | map(sub("^[a-z-]+:"; "") | h) | join(" → ")),
"<h3>Beyond the depth limit</h3>", ul($V.truncated; "\(.label | h) (\((.module // "no module") | h), depth \(.depth))"),
"</div></details>",
"</section>",

# ---------------------------------------------------------------- questions and review
"<section id=\"questions\"><h2>Open questions, assumptions and actions</h2>",
"<h3>Open questions</h3>", ul($V.open_questions; "<span id=\"q-\(.id | h)\"><b>\(.id | h)</b> (\(.role | h))</span> \(.question | h)\(if ((.blocks // []) | length) > 0 then " <span class=\"muted\">affects \(.blocks | map(h) | join(", "))</span>" else "" end)"),
"<h3>Assumptions</h3>", ul($V.assumptions; "<span id=\"a-\(.id | h)\"><b>\(.id | h)</b></span> \(.text | h)\(if ((.affects // []) | length) > 0 then " <span class=\"muted\">affects \(.affects | map(h) | join(", "))</span>" else "" end)"),
"<h3>Recommended actions</h3>", ul($V.actions; "(\(.role | h)) \(.text | h)"),
"</section>",
"<section id=\"review\"><h2>Review status</h2>",
"<p><span class=\"badge draft\">Draft</span> Only a human moves this analysis to Reviewed or Approved. Reviewer: \($V.reviewer | h).</p>",
"<p class=\"muted\">Rendered from <code>impact-facts.json</code> (facts sha256 <code>\($V.sha[0:12] | h)</code>), the same data as <code>impact.md</code>. Checks: <code>checks/impact-check.md</code>.\(if ($V.map_behind | length) > 0 then " Warning: _map is behind HEAD (" + ($V.map_behind | map(h) | join("; ")) + ")." else "" end)</p>",
"</section>",
"</main>",
"<footer>atreya /atreya:impact · self-contained report: no external requests · Draft</footer>"
] | join("\n")
end
