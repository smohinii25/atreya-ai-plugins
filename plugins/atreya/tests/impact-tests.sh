#!/bin/bash
# Tests for /atreya:impact v2 (impact-facts.sh graph + risk rules, impact-render.sh,
# impact-check.sh, the controllers.sh map extension). FAKE fixtures only: a
# throwaway workspace from tests/fixtures/impact/make-workspace.sh under $TMPDIR.
# Prints PASS/FAIL; exit 1 if any FAIL.
#
#   bash plugins/atreya/tests/impact-tests.sh

HERE=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN=$(cd "$HERE/.." && pwd -P)
S="$PLUGIN/scripts"; FX="$HERE/fixtures/impact"
T=$(mktemp -d "${TMPDIR:-/tmp}/atreya-impact-tests.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
if [ -n "${ATREYA_KEEP_TEST_DIR:-}" ]; then echo "test workspace kept: $T"; else trap 'rm -rf "$T"' EXIT; fi

PASSN=0; FAILN=0
ok()   { PASSN=$((PASSN+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAILN=$((FAILN+1)); printf 'FAIL  %s\n' "$1"; [ -n "$2" ] && printf '        %s\n' "$2"; }
expect_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac; }
expect_absent()   { case "$2" in *"$3"*) bad "$1" "should not contain: $3" ;; *) ok "$1" ;; esac; }
expect_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
section() { printf '\n== %s\n' "$1"; }

W="$T/ws"; RT="--root $W"; DEV="$W/atreya-docs/dev"; MAP="$W/atreya-docs/_map"
bash "$FX/make-workspace.sh" "$W" "$PLUGIN" >/dev/null 2>"$T/mk.err" || { echo "fixture build failed:"; cat "$T/mk.err"; exit 1; }
B="$W/repos/be"
ln_of() { grep -n "$2" "$B/$1" | head -n 1 | cut -d: -f1; }   # ln_of FILE PATTERN -> first line number
IF() { bash "$S/impact-facts.sh" $RT --ticket "$@" 2>&1; }
IJ() { /usr/bin/jq -r "$2" "$DEV/$1/impact-facts.json" 2>&1; }
RENDER() { bash "$S/impact-render.sh" $RT --ticket "$1" --analysis "$2" 2>&1; }
CHECK() { bash "$S/impact-check.sh" $RT --ticket "$@" 2>&1; }
# mut TICKET JQ_FILTER -> render the base analysis changed by JQ_FILTER; prints the output
BASE="$FX/analysis-ledger.json"
mut() { /usr/bin/jq "$2" "$BASE" > "$T/mut.json" && RENDER "$1" "$T/mut.json"; }
PAY="app/Http/Controllers/PayController.php"; LED="app/Services/LedgerService.php"

# ---------------------------------------------------------------- map extension
section "map: controllers.sh records uses, writes, transactions, classes, events"
CJ="$MAP/be/controllers.json"
expect_eq "service used via promoted property, event via new" \
  "$(/usr/bin/jq -r '.controllers[] | select(.fqcn | endswith("PayController")) | .methods[] | select(.name == "pay") | [.uses[] | "\(.class | split("\\") | last):\(.kind)"] | join(",")' "$CJ")" \
  "PaymentDone:event,LedgerService:service"
expect_eq "service used via a type-hinted parameter" \
  "$(/usr/bin/jq -r '.controllers[] | select(.fqcn | endswith("LedgerController")) | .methods[0].uses | map(.class | split("\\") | last) | join(",")' "$CJ")" "LedgerService"
expect_eq "writes: model create (table from models.json) and DB::table update" \
  "$(/usr/bin/jq -r '.controllers[] | select(.fqcn | endswith("PayController")) | .methods[] | select(.name == "pay") | [.writes[] | "\(.table)/\(.via)"] | join(",")' "$CJ")" \
  "payments/model Payment,wallets/DB::table"
expect_eq "transaction detected (and absent where there is none)" \
  "$(/usr/bin/jq -r '[.controllers[] | .methods[] | select(.name == "refund" or .name == "pay") | "\(.name)=\(.transaction)"] | sort | join(",")' "$CJ")" "pay=false,refund=true"
expect_eq "\$var->delete()/save() resolve to the model it was assigned from or type-hinted as; else ?" \
  "$(/usr/bin/jq -r '.controllers[] | select(.fqcn | endswith("PayController")) | .methods[] | select(.name == "cancel") | [.writes[] | "\(.table)/\(.via)/\(.lines | length)"] | join(",")' "$CJ")" \
  "?/unknown model/1,payments/model Payment/2"
expect_eq "other app classes are mapped with their kind" \
  "$(/usr/bin/jq -r '[.classes[] | "\(.fqcn | split("\\") | last):\(.kind)"] | sort | join(",")' "$CJ")" "Helper:service,LedgerService:service,PaymentDone:event,SendReceipt:listener"
expect_eq "unqualified same-namespace class counts (Helper in App\\Services)" \
  "$(/usr/bin/jq -r '.classes[] | select(.fqcn | endswith("LedgerService")) | .methods[0].uses | map(.class | split("\\") | last) | join(",")' "$CJ")" "Helper"
expect_eq "events from EventServiceProvider \$listen" "$(/usr/bin/jq -r '.events[] | "\(.event | split("\\") | last)->\(.listeners | map(split("\\") | last) | join(","))"' "$CJ")" "PaymentDone->SendReceipt"
expect_eq "v1 fields and counts unchanged in shape" "$(/usr/bin/jq -r '.controllers[0].methods[0] | keys | join(",")' "$CJ")" "lines,models,name,tables,transaction,uses,views,writes"
H1=$(shasum < "$CJ"); bash "$S/controllers.sh" $RT be >/dev/null 2>&1
expect_eq "controllers.sh is deterministic" "$(shasum < "$CJ")" "$H1"

# ---------------------------------------------------------------- direct + indirect
section "impact: direct and indirect (one hop) dependencies"
IO=$(IF t-pay --file "be:$PAY:$(ln_of "$PAY" 'Payment::create')")
expect_contains "summary line keeps the v1 format" "$IO" "impact-facts: t-pay: 1 direct + "
expect_contains "summary line v2" "$IO" "impact-facts v2: 3 indirect modules"
expect_eq "direct: the module that owns the changed code" "$(IJ t-pay '[.modules[] | select(.role == "direct") | .id] | join(",")')" "payments"
expect_eq "indirect via API callers (web and app) = upstream, depth 1" \
  "$(IJ t-pay '[.modules[] | select(.id == "shop" or .id == "app-pay") | "\(.id):\(.direction):\(.depth)"] | sort | join(",")')" "app-pay:upstream:1,shop:upstream:1"
expect_eq "indirect via event → listener = downstream" "$(IJ t-pay '.modules[] | select(.id == "receipts") | "\(.direction):\(.depth)"')" "downstream:1"
expect_contains "why = the cited path" "$(IJ t-pay '.modules[] | select(.id == "receipts") | .why[0]')" "PayController@pay → SendReceipt@handle"
expect_eq "indirect evidence is Verified with the edge citations" "$(IJ t-pay '.modules[] | select(.id == "shop") | "\(.evidence.class) \(.evidence.cites | length > 0)"')" "Verified true"
expect_eq "events: emitted at file:line with the listener's module" "$(IJ t-pay '.events[0] | "\(.emitted_at | split(":") | .[0:2] | join(":")) \(.listeners[0].module)"')" "be:$PAY receipts"
IF adhoc-led --file "be:$LED:$(ln_of "$LED" 'DB::table')" >/dev/null
expect_eq "indirect via a shared service: its users are upstream" "$(IJ adhoc-led '.modules[] | select(.id == "payments") | "\(.role):\(.direction):\(.depth)"')" "indirect:upstream:1"
IF t-table --table payments --file "be:app/Http/Controllers/ReportController.php" >/dev/null
expect_eq "indirect via a changed table: readers/writers are downstream" \
  "$(IJ t-table '[.modules[] | select(.id == "payments" or .id == "refunds") | "\(.id):\(.direction)"] | sort | join(",")')" "payments:downstream,refunds:downstream"
expect_eq "v1 related modules still computed" "$(IJ t-table '[.related_modules[].id] | sort | join(",")')" "payments,refunds"

# ---------------------------------------------------------------- multi-hop, depth, cycles
section "impact: multi-hop, depth limit, circular dependencies"
expect_eq "multi-hop: service → controller → route → app caller (depth 2)" "$(IJ adhoc-led '.modules[] | select(.id == "app-pay") | "\(.depth):\(.direction)"')" "2:upstream"
expect_contains "multi-hop path is listed hop by hop" "$(IJ adhoc-led '.modules[] | select(.id == "app-pay") | .why[0]')" "LedgerService@post → PayController@pay → POST api/pay → payNow (ap)"
expect_eq "multi-hop: upstream then event = downstream" "$(IJ adhoc-led '.modules[] | select(.id == "receipts") | "\(.depth):\(.direction)"')" "2:downstream"
IF t-led1 --depth 1 --file "be:$LED:$(ln_of "$LED" 'DB::table')" >/dev/null
expect_eq "--depth 1 stops after one module hop" "$(IJ t-led1 '[.modules[].id] | join(",")')" "ledger,payments,shop"
expect_eq "…and lists what lies beyond" "$(IJ t-led1 '[.truncated[] | "\(.module):\(.depth)"] | sort | join(",")')" "app-pay:2,receipts:2"
expect_contains "--depth outside 1-5 is refused" "$(IF t-x --depth 9 --module ledger)" "--depth must be 1-5"
expect_eq "circular use (LedgerService ↔ Helper) is recorded once" "$(IJ adhoc-led '.cycles | length')" "1"
expect_contains "…as a path back to the start" "$(IJ adhoc-led '.cycles[0].path | join(" > ")')" "Helper@round > method:be:App\\Services\\LedgerService@post"
expect_eq "…and every module appears once" "$(IJ adhoc-led '[.modules[].id] | (length == (unique | length))')" "true"

# ---------------------------------------------------------------- missing and unknown links
section "impact: missing and unknown links"
IF t-login --file "be:app/Http/Controllers/LoginController.php:$(ln_of app/Http/Controllers/LoginController.php 'return 1')" >/dev/null
expect_contains "a changed route no client calls is Unknown (not 'safe')" "$(IJ t-login '[.unknowns[].what] | join(";")')" "callers of POST api/login"
IF t-track --file "fe:app/Http/Controllers/ShopController.php:13" >/dev/null
expect_contains "an unresolved API call in the changed code is Unknown" "$(IJ t-track '[.unknowns[] | "\(.what): \(.why)"] | join(";")')" "API call at fe:app/Http/Controllers/ShopController.php:13: path is fully dynamic"
expect_contains "shared state outside routes/tables is always listed" "$(IJ t-track '[.unknowns[].what] | join(";")')" "state shared outside routes and tables"
expect_contains "unknown seeds still refused" "$(IF t-bad --route "POST nope")" "unknown route POST nope"
cp "$MAP/be/controllers.json" "$T/ctl.json"
/usr/bin/jq 'del(.classes, .events) | .controllers |= map(.methods |= map(del(.uses, .writes, .transaction)))' "$T/ctl.json" > "$MAP/be/controllers.json"
IF t-old --file "be:$PAY:$(ln_of "$PAY" 'Payment::create')" >/dev/null
expect_contains "a map without services/events data: they are Unknown" "$(IJ t-old '[.unknowns[].why] | join(";")')" "has no services/events data"
expect_eq "…and v1 results do not change" "$(IJ t-old '[.direct_modules[].id, .backend_routes[].key] | join(",")')" "$(IJ t-pay '[.direct_modules[].id, .backend_routes[].key] | join(",")')"
expect_eq "…map_features says so" "$(IJ t-old '.map_features.be.uses')" "false"
cp "$T/ctl.json" "$MAP/be/controllers.json"

# ---------------------------------------------------------------- conflicting evidence
section "impact: conflicting evidence"
IF t-help --file "be:app/Services/Helper.php" >/dev/null
expect_eq "a changed file owned by two modules is a conflict" "$(IJ t-help '.conflicts[0].what')" "be:app/Services/Helper.php is owned by 2 modules"
expect_eq "…both owners are direct" "$(IJ t-help '[.modules[] | select(.role == "direct") | .id] | sort | join(",")')" "audit,ledger"
expect_eq "…and the overall confidence is Low" "$(IJ t-help '.risk_overall.confidence')" "Low"
O=$(mut adhoc-led '.not_affected = [{"id": "payments", "reason": "unchanged", "evidence": {"class": "Not affected", "cites": [], "note": "checked"}}]')
expect_contains "analysis saying 'not affected' for a module the facts reach is refused" "$O" "not_affected: payments contradicts the facts"
expect_absent "…and nothing was written" "$(ls "$DEV/adhoc-led")" "impact.md"

# ---------------------------------------------------------------- data consistency and money
section "impact: data-consistency and financial risks"
expect_contains "two writes without a transaction (money table) → DATA-03 High" "$(IJ t-pay '[.risks[] | "\(.rule):\(.level)"] | join(",")')" "DATA-03:High"
expect_contains "a write to a money table → MONEY-02 Critical" "$(IJ t-pay '[.risks[] | "\(.rule):\(.level)"] | join(",")')" "MONEY-02:Critical"
expect_eq "overall Critical, from the rule" "$(IJ t-pay '"\(.risk_overall.level) \(.risk_overall.rules | join(","))"')" "Critical MONEY-02"
IF t-refund --file "be:app/Http/Controllers/RefundController.php:$(ln_of app/Http/Controllers/RefundController.php 'DB::table')" >/dev/null
expect_absent "the same writes inside DB::transaction → no DATA-03" "$(IJ t-refund '[.risks[].rule] | join(",")')" "DATA-03"
expect_eq "data flow: every write with its file:line" "$(IJ t-pay '[.data_flow[] | select(.op == "write") | .table] | sort | join(",")')" "payments,wallets"
expect_contains "readers of a written (not changed) table are not affected, with the reason" "$(IJ adhoc-led '.not_affected[] | select(.id == "reports") | .reason')" "does not change its structure or meaning"
expect_eq "v1 risk level still computed" "$(IJ t-pay '.risk.level')" "High"

# ---------------------------------------------------------------- risk explainability
section "impact: every risk level can be explained"
RULES=$(grep -oE '^\| [A-Z]+-[0-9]{2} ' "$PLUGIN/references/impact-risk-rules.md" | tr -d '| ')
BADR=""; for t in t-pay adhoc-led t-table t-login t-help; do
  BADR="$BADR$(IJ $t '.risks[] | select((.rule // "") == "" or (.reason // "") == "" or (.consequence // "") == "" or (.evidence.class // "") == "" or (.level | IN("Critical","High","Medium","Low") | not)) | .id')"
  for r in $(IJ $t '.risks[].rule'); do printf '%s\n' "$RULES" | grep -qx "$r" || BADR="$BADR $t:$r"; done; done
expect_eq "every risk record has rule (documented), level, reason, consequence, evidence" "$BADR" ""
expect_eq "name-pattern rules are Inferred, not Verified" "$(IJ t-login '[.risks[] | select(.rule == "SEC-01") | .evidence.class] | unique | join(",")')" "Inferred"
O=$(mut adhoc-led '.risks += [{"id": "RA-02", "rule": "FAIL-04", "level": "Low", "raises": "RS-01", "reason": "r", "consequence": "c", "evidence": {"class": "Inferred", "cites": ["facts:risks"]}}]')
expect_contains "an analysis risk can never lower a script risk" "$O" "a risk can only be raised, never lowered"
O=$(mut adhoc-led '.risks[0].level = "Low"')
expect_contains "FAIL rules have a fixed level" "$O" "RA-01: FAIL-02 has a fixed level"
O=$(mut adhoc-led '.risks[0].rule = "MADE-UP"')
expect_contains "an undocumented rule is refused" "$O" "rule must be one of references/impact-risk-rules.md"

# ---------------------------------------------------------------- requirements
section "impact: requirement understanding and missing requirements"
O=$(mut adhoc-led '.requirement.proposed = [] | .requirement.missing = []')
expect_contains "no proposed behaviour and nothing listed as missing → refused" "$O" "requirement.proposed is empty"
O=$(mut adhoc-led '.requirement.missing[0].question = "Q9"')
expect_contains "a missing requirement must link an open question" "$O" "needs a question id from open_questions"
O=$(mut adhoc-led '.requirement.proposed = []')
expect_contains "proposed may be empty when the gap is listed as missing" "$O" "wrote $DEV/adhoc-led/impact.md"
expect_contains "missing requirements appear in impact.md §1" "$(cat "$DEV/adhoc-led/impact.md")" "What happens to existing unrounded rows? (→ Q2)"

# ---------------------------------------------------------------- evidence rules
section "impact: evidence classes are enforced"
expect_contains "Verified without a citation is refused" "$(mut adhoc-led '.requirement.current[0].evidence.cites = []')" "Verified needs a Repo:path:line citation"
expect_contains "Verified with a line past the end of the file is refused" "$(mut adhoc-led '.requirement.current[0].evidence.cites = ["be:'"$LED"':999"]')" "(file has"
expect_contains "Verified on a secret file is refused" "$(mut adhoc-led '.requirement.current[0].evidence.cites = ["be:.env:1"]')" "Verified citation does not hold"
expect_contains "Inferred must cite what it is derived from" "$(mut adhoc-led '.requirement.proposed[0].evidence.cites = []')" "Inferred must cite what it was derived from"
expect_contains "facts:<key> must exist" "$(mut adhoc-led '.requirement.proposed[0].evidence.cites = ["facts:nope"]')" "facts:nope: no such key"
expect_contains "an Assumption must be listed under assumptions" "$(mut adhoc-led '.workflow[2].evidence.assumption = "A9"')" "an Assumption must name its entry in assumptions"
expect_contains "an unknown evidence class is refused" "$(mut adhoc-led '.workflow[0].evidence.class = "Probably"')" "evidence class \"Probably\" is not one of"
expect_contains "QA 'Passed' without a QA report is refused (never 'executed')" "$(mut adhoc-led '.qa_scenarios[0].status = "Passed"')" "QA-01: status Passed needs evidence.report"
expect_contains "QA 'Executed' is not a status" "$(mut adhoc-led '.qa_scenarios[0].status = "Executed"')" "status \"Executed\" is not allowed"
mkdir -p "$W/atreya-qa/reports"; echo "fake run" > "$W/atreya-qa/reports/run-1.md"
expect_contains "QA 'Passed' with an existing QA report is accepted" \
  "$(mut adhoc-led '.qa_scenarios[0].status = "Passed" | .qa_scenarios[0].evidence = {"class": "Verified", "cites": ["be:'"$LED"':6"], "report": "atreya-qa/reports/run-1.md"}')" "wrote $DEV/adhoc-led/impact.md"
expect_contains "a report outside atreya-docs/atreya-qa is refused" \
  "$(mut adhoc-led '.qa_scenarios[0].status = "Failed" | .qa_scenarios[0].evidence = {"class": "Inferred", "cites": ["facts:qa"], "report": "../../etc/passwd"}')" "QA report ../../etc/passwd"
expect_contains "an existing scenario must trace to an existing test" "$(mut adhoc-led '.qa_scenarios[0].origin = "existing" | .qa_scenarios[0].trace = ["LEDGER-R01"]')" "an existing scenario must trace"
expect_contains "an invented requirement ID is refused" "$(mut adhoc-led '.traceability = [{"ref": "LEDGER-R99", "note": "x"}]')" "requirement LEDGER-R99 is not in the facts"
expect_contains "the analysis cannot set a review status" "$(mut adhoc-led '.review = {"status": "Approved"}')" "review: the review status is set by a human"
expect_contains "unknown sections are refused" "$(mut adhoc-led '.extra = 1')" "extra: not a known analysis section"
expect_contains "module_notes only for affected modules" "$(mut adhoc-led '.module_notes.nowhere = {"description": "x"}')" "module_notes.nowhere: not an affected module"
expect_contains "added_modules must exist in modules.yaml (never invent modules)" "$(mut adhoc-led '.added_modules = [{"id": "ghost", "why": "x", "evidence": {"class": "Inferred", "cites": ["facts:code"]}}]')" "added_modules: ghost is not a module in modules.yaml"
expect_contains "workflow steps need before/after/on_failure" "$(mut adhoc-led 'del(.workflow[0].on_failure)')" "workflow step 1: actor, before, after and on_failure are required"

# ---------------------------------------------------------------- render + check (free text)
section "render: impact.md and impact-report.html from impact-facts.json"
IF adhoc-ledger-rounding --file "be:$LED:$(ln_of "$LED" 'DB::table')" >/dev/null
RO=$(RENDER adhoc-ledger-rounding "$BASE")
expect_contains "render writes both reports" "$RO" "wrote $DEV/adhoc-ledger-rounding/impact.md and $DEV/adhoc-ledger-rounding/impact-report.html"
D="$DEV/adhoc-ledger-rounding"; MD=$(cat "$D/impact.md"); HT=$(cat "$D/impact-report.html")
CK=$(CHECK adhoc-ledger-rounding)
expect_contains "impact-check passes a good run" "$CK" "impact-check: PASS"
expect_contains "…including check-doc (12 headings, citations, keys)" "$CK" "PASS  check-doc.sh passes impact.md"
expect_eq "impact.md keeps the 12 template headings" "$(grep -E '^## [0-9]+\. ' "$D/impact.md")" "$(grep -E '^## [0-9]+\. ' "$PLUGIN/references/impact-template.md")"
expect_contains "status Draft in impact.md" "$MD" 'status: "Draft"'
expect_eq "status Draft in the JSON" "$(IJ adhoc-ledger-rounding '.review.status')" "Draft"
expect_contains "free-text source shown" "$MD" "- **Source**: free text"
expect_contains "indirect modules with depth and direction in impact.md" "$MD" "| **app-pay** | 2 | upstream |"
expect_contains "workflow before/after/if it fails" "$MD" "| 2 | System | payments | POST api/pay | Ledger gets the raw amount | Ledger gets the rounded amount | Payment stored but ledger missing: totals disagree |"
expect_contains "QA status is Not run" "$MD" "| QA-01 | shop | 1 | positive | suggested | Checkout 10.005 | ledger shows 10.01 | none | Not run |"
expect_contains "a not-affected module with a scenario is in the QA scope" "$MD" "**reports** (not affected)"
expect_contains "html: executive summary with counts" "$HT" 'data-count="indirect">4<'
expect_contains "html: overall risk" "$HT" 'data-risk-level="Critical"'
expect_contains "html: dependency map data" "$HT" '<script type="application/json" id="atreya-data">'
expect_contains "html: module drill-down" "$HT" 'id="mod-payments" data-module="payments"'
expect_contains "html: workflow step" "$HT" 'id="step-2"'
expect_contains "html: Draft badge" "$HT" 'data-status="Draft"'
expect_contains "the summary names the change, modules, risk, missing info, paths" "$(CHECK adhoc-ledger-rounding --summary)" "- Missing information: 2 open question(s) (Q1 PO, Q2 Dev), 1 missing requirement(s), 1 assumption(s)"
H1=$(cat "$D/impact.md" "$D/impact-report.html" | shasum); RENDER adhoc-ledger-rounding "$BASE" >/dev/null
expect_eq "rendering twice gives identical reports" "$(cat "$D/impact.md" "$D/impact-report.html" | shasum)" "$H1"
bash "$S/impact-render.sh" $RT --ticket adhoc-ledger-rounding >/dev/null 2>&1
expect_eq "re-render without --analysis uses the merged analysis" "$(cat "$D/impact.md" "$D/impact-report.html" | shasum)" "$H1"

# ---------------------------------------------------------------- HTML injection
section "html: everything from the input is escaped"
INJ='</script><script>alert(1)</script>'; IMG='"><img src=x onerror=alert(2)>'
IF adhoc-inject --file "be:$LED:$(ln_of "$LED" 'DB::table')" >/dev/null
/usr/bin/jq --arg a "$INJ" --arg b "$IMG" '.input.title = "Round \($a)" | .input.text = "x \($b) https://evil.example/x.js" |
   .module_notes.ledger.description = $a | .qa_scenarios[0].title = $b | .workflow[0].before = "<b>bold</b> javascript:alert(3)" |
   .open_questions[0].question = "<iframe src=//evil.example>"' "$BASE" > "$T/inj.json"
RENDER adhoc-inject "$T/inj.json" >/dev/null
HT=$(cat "$DEV/adhoc-inject/impact-report.html"); MD=$(cat "$DEV/adhoc-inject/impact.md")
expect_absent "no raw <script> from the input" "$HT" "<script>alert(1)"
expect_absent "no raw <img> from the input" "$HT" "<img src=x"
expect_absent "no raw <iframe> from the input" "$HT" "<iframe"
expect_absent "no raw <b> from the input" "$HT" "<b>bold</b>"
expect_contains "the title is shown escaped" "$HT" "Round &lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;"
expect_contains "the attribute-breaking quote is escaped" "$HT" "&quot;&gt;&lt;img src=x onerror=alert(2)&gt;"
expect_eq "exactly two script elements" "$(grep -oi '<script' "$DEV/adhoc-inject/impact-report.html" | grep -c .)" "2"
expect_absent "the map data cannot close its script element" "$(grep -o '<script type="application/json" id="atreya-data">.*</script>' "$DEV/adhoc-inject/impact-report.html" | sed 's#</script>$##')" "</script"
expect_absent "impact.md does not carry raw HTML either" "$MD" "<script>"
expect_contains "impact-check passes the escaped report" "$(CHECK adhoc-inject)" "impact-check: PASS"
cp "$DEV/adhoc-inject/impact-report.html" "$T/h.bak"
sed -i '' 's#<footer>#<img src="https://evil.example/t.gif"><footer>#' "$DEV/adhoc-inject/impact-report.html"
O=$(CHECK adhoc-inject); expect_contains "impact-check catches a raw external image" "$O" "FAIL  no external URL"
expect_contains "…and the injected tag" "$O" "FAIL  no injected tags or inline event handlers"
cp "$T/h.bak" "$DEV/adhoc-inject/impact-report.html"
sed -i '' 's#<footer>#<div onclick="x()"></div><footer>#' "$DEV/adhoc-inject/impact-report.html"
expect_contains "impact-check catches an inline event handler" "$(CHECK adhoc-inject)" "FAIL  no injected tags or inline event handlers"
cp "$T/h.bak" "$DEV/adhoc-inject/impact-report.html"

# ---------------------------------------------------------------- no external URLs
section "html: one self-contained file, no external requests"
TPL="$PLUGIN/scripts/lib/impact-report.html"
expect_eq "the template's only URL is the SVG namespace (not a request)" "$(grep -oE 'https?://[^"'"'"' )]+' "$TPL" | sort -u | tr '\n' ' ')" "http://www.w3.org/2000/svg "
expect_absent "no <link>, no <script src>, no @import in the template" "$(grep -iE '<link|<script[^>]+src|@import|url\(' "$TPL")" "<"
expect_absent "no innerHTML / eval / new Function / document.write / fetch in the template" "$(grep -E 'innerHTML|outerHTML|insertAdjacentHTML|eval\(|new Function|document\.write|fetch\(|XMLHttpRequest|WebSocket|sendBeacon' "$TPL")" "("
expect_contains "CSP default-src 'none'" "$(cat "$DEV/adhoc-ledger-rounding/impact-report.html")" "content=\"default-src 'none';"
expect_eq "no src/href to http(s) or // in a report" "$(grep -oiE '(src|href)="(https?:|//)' "$DEV/adhoc-ledger-rounding/impact-report.html" "$DEV/adhoc-inject/impact-report.html" | grep -c .)" "0"
expect_contains "inline CSS and JS (print and small-screen rules included)" "$(cat "$DEV/adhoc-ledger-rounding/impact-report.html")" "@media print"

# ---------------------------------------------------------------- consistency md ↔ html ↔ json
section "consistency: impact.md, impact-report.html and impact-facts.json agree"
D="$DEV/adhoc-ledger-rounding"; cp "$D/impact-report.html" "$T/h.bak"; cp "$D/impact.md" "$T/m.bak"; cp "$D/impact-facts.json" "$T/f.bak"
sed -i '' 's/id="mod-receipts"/id="mod-elsewhere"/' "$D/impact-report.html"
O=$(CHECK adhoc-ledger-rounding); expect_contains "a module missing from the HTML is caught" "$O" "missing: receipts"; expect_contains "…and the extra one" "$O" "extra: elsewhere"
cp "$T/h.bak" "$D/impact-report.html"
grep -v '^| RA-01 |' "$T/m.bak" > "$D/impact.md"
expect_contains "a risk missing from impact.md is caught" "$(CHECK adhoc-ledger-rounding)" "FAIL  impact.md §9 lists exactly the JSON's risks"
sed 's/\*\*Indirect modules\*\*: 4/**Indirect modules**: 3/' "$T/m.bak" > "$D/impact.md"
expect_contains "a wrong count in impact.md is caught" "$(CHECK adhoc-ledger-rounding)" "FAIL  impact.md counts and overall risk match the JSON"
sed 's/^status: "Draft"$/status: "Approved"/' "$T/m.bak" > "$D/impact.md"
expect_contains "a generated impact.md marked Approved is caught" "$(CHECK adhoc-ledger-rounding)" "FAIL  status Draft (impact.md)"
cp "$T/m.bak" "$D/impact.md"
/usr/bin/jq '.modules |= map(select(.id != "receipts"))' "$T/f.bak" > "$D/impact-facts.json"
expect_contains "edited script facts are caught (hash)" "$(CHECK adhoc-ledger-rounding)" "FAIL  script facts untouched (facts_sha256)"
expect_contains "…and render refuses them" "$(bash "$S/impact-render.sh" $RT --ticket adhoc-ledger-rounding 2>&1)" "were edited (facts_sha256 differs)"
cp "$T/f.bak" "$D/impact-facts.json"
expect_contains "restored run passes again" "$(CHECK adhoc-ledger-rounding)" "impact-check: PASS"
cp "$BASE" "$D/.analysis-draft.json"
expect_contains "--final removes the merged draft when everything passes" "$(CHECK adhoc-ledger-rounding --final)" "removed the analysis draft"
expect_absent "…it is gone" "$(ls -a "$D")" ".analysis-draft.json"

# ---------------------------------------------------------------- Zoho item vs free text
section "input: Zoho Sprints item and free text"
IF NT-42 --file "be:$LED:$(ln_of "$LED" 'DB::table')" >/dev/null
Z='.input = {"source": "zoho", "id": "NT-42", "title": "Round ledger amounts", "text": "As finance I want ledger amounts rounded"} | .requirement.proposed[0].evidence = {"class": "Verified", "cites": ["Zoho Sprints NT-42"]}'
expect_contains "a Zoho item renders (its own text may be cited as Verified)" "$(mut NT-42 "$Z")" "wrote $DEV/NT-42/impact.md"
expect_contains "impact.md names the Zoho item" "$(cat "$DEV/NT-42/impact.md")" "- **Source**: Zoho Sprints NT-42"
expect_contains "…and the stamp carries the ticket" "$(cat "$DEV/NT-42/impact.md")" 'ticket: "NT-42"'
expect_contains "html names the Zoho item" "$(cat "$DEV/NT-42/impact-report.html")" "Zoho Sprints NT-42"
expect_contains "Zoho run passes impact-check" "$(CHECK NT-42)" "impact-check: PASS"
expect_contains "a Zoho id that is not the ticket is refused" "$(mut NT-42 "$Z | .input.id = \"NT-7\"")" "input.id NT-7 is not the ticket NT-42"
expect_contains "citing another Zoho item as Verified is refused" "$(mut NT-42 "$Z | .requirement.proposed[0].evidence.cites = [\"Zoho Sprints NT-7\"]")" "Verified accepts only Repo:path:line citations"
expect_contains "free text needs an adhoc- ticket" "$(mut NT-42 '.')" "free-text input needs an adhoc-<slug> ticket"
expect_contains "a Zoho citation in a free-text run is not Verified" "$(mut adhoc-ledger-rounding '.requirement.proposed[0].evidence = {"class": "Verified", "cites": ["Zoho Sprints NT-42"]}')" "Verified accepts only Repo:path:line citations"

# ---------------------------------------------------------------- secrets
section "secrets: never in any output"
FAKE=FAKEtoken987654321
O=$(mut adhoc-ledger-rounding ".summary.headline = \"api_token = \\\"$FAKE\\\"\"")
expect_contains "a key-like string in the analysis is refused" "$O" "key-like string in the analysis"
expect_absent "…and its value is never printed" "$O" "$FAKE"
expect_absent "…nor written" "$(cat "$DEV/adhoc-ledger-rounding/impact.md" "$DEV/adhoc-ledger-rounding/impact-report.html" "$DEV/adhoc-ledger-rounding/impact-facts.json")" "$FAKE"

printf '\n%d passed, %d failed\n' "$PASSN" "$FAILN"
[ $FAILN = 0 ]
