#!/bin/bash
# impact-check.sh [--root R] --ticket T [--dir DIR] [--summary | --final]
#
# Mechanical checks of one impact run (dev/T/ or --dir), after impact-render.sh:
#   1. impact-facts.json: schema v2, script facts untouched (facts_sha256),
#      analysis merged, review status Draft
#   2. impact.md: check-doc.sh passes (stamp, 12 headings, citations, keys);
#      status Draft
#   3. impact.md and impact-report.html say the same as the JSON: counts,
#      overall risk, and exactly the same module / risk / question / assumption /
#      QA scenario IDs (nothing missing, nothing extra)
#   4. impact-report.html is self-contained and safe: CSP present, the app
#      script is byte-identical to lib/impact-report.html, exactly one data
#      script (valid JSON), no external URL in src/href/action/url()/@import, no
#      injected tags or inline handlers
#   5. no key-like strings in the JSON, the Markdown or the HTML
# Prints PASS/FAIL per check; exit 1 if any FAIL. --summary also prints the
# end-of-run summary (change, modules, risk, missing information, paths, results).
# --final = --summary, and when every check passes, removes the analysis draft
# (DIR/.analysis-draft.json): its content now lives in impact-facts.json.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
SLUG=""; DIR=""; SUM=0; FINAL=0
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do case "$1" in
  --ticket) SLUG="$2"; shift 2 ;; --dir) DIR="$2"; shift 2 ;; --summary) SUM=1; shift ;; --final) SUM=1; FINAL=1; shift ;;
  *) die "unknown argument $1" ;; esac; done
case "$SLUG" in ""|*[!A-Za-z0-9._-]*|.*) die "usage: impact-check.sh --root R --ticket T [--dir DIR] [--summary | --final]" ;; esac
[ -n "$DIR" ] || DIR="$DOCS/dev/$SLUG"
FJ="$DIR/impact-facts.json"; MD="$DIR/impact.md"; HT="$DIR/impact-report.html"
FAILS=0; RESULTS=""
ok()   { echo "PASS  $1"; RESULTS="${RESULTS}PASS  $1
"; }
fail() { echo "FAIL  $1"; [ -n "$2" ] && printf '%s\n' "$2" | grep . | head -20 | sed 's/^/        /'; FAILS=$((FAILS+1)); RESULTS="${RESULTS}FAIL  $1
"; }
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atreya-icheck.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT
for f in "$FJ" "$MD" "$HT"; do [ -f "$f" ] || die "missing $f (run impact-facts.sh and impact-render.sh)"; done

# ---- 1. the JSON
if "$JQ" -e '.schema == "atreya.impact/2"' "$FJ" >/dev/null 2>&1; then ok "impact-facts.json is schema atreya.impact/2"; else fail "impact-facts.json is schema atreya.impact/2"; fi
SHA=$("$JQ" -S -c 'del(.analysis, .review, .facts_sha256)' "$FJ" | shasum -a 256 | cut -d' ' -f1)
[ "$SHA" = "$("$JQ" -r '.facts_sha256' "$FJ")" ] && ok "script facts untouched (facts_sha256)" || fail "script facts untouched (facts_sha256)" "the facts part of impact-facts.json was edited after impact-facts.sh wrote it"
"$JQ" -e '.analysis | type == "object"' "$FJ" >/dev/null && ok "analysis merged" || fail "analysis merged" "run impact-render.sh --analysis DRAFT.json"
[ "$("$JQ" -r '.review.status' "$FJ")" = Draft ] && ok "review status Draft (json)" || fail "review status Draft (json)" "a generated analysis is never Reviewed/Approved"

# ---- 2. impact.md
CD=$(bash "$ATREYA_SCRIPTS/check-doc.sh" --root "$ROOT" "$MD" 2>&1)
if [ $? = 0 ]; then ok "check-doc.sh passes impact.md"; else fail "check-doc.sh passes impact.md" "$(printf '%s\n' "$CD" | grep -E '^(FAIL|  )')"; fi
WARNS=$(printf '%s\n' "$CD" | grep -c '^WARN')
[ "$(bash "$ATREYA_SCRIPTS/yaml2json.sh" --front-matter "$MD" 2>/dev/null | "$JQ" -r '.status')" = Draft ] && ok "status Draft (impact.md)" || fail "status Draft (impact.md)"

# ---- 3. same content: expected values from the shared view
"$JQ" -L "$ATREYA_LIB" 'include "impact-view"; view | {direct: .counts.direct, indirect: .counts.indirect, level: .risk.level,
   modules: [.modules[].id], risks: [.risks[].id], questions: [.open_questions[].id], assumptions: [.assumptions[].id],
   scenarios: [.qa_scenarios[].id]}' "$FJ" > "$TMPD/x.json" 2>/dev/null || { fail "view of impact-facts.json"; echo "impact-check: FAIL"; exit 1; }
X() { "$JQ" -r "$1" "$TMPD/x.json"; }
# sets found in each report (sorted, one per line)
set_of() { sort -u | grep . ; }
cmp_set() {  # cmp_set LABEL EXPECTED FOUND
  if [ "$2" = "$3" ]; then ok "$1"; else
    fail "$1" "$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | grep '^[<>]' | sed 's/^</missing:/; s/^>/extra:/')"; fi
}
BODY=$(awk 'f; /^---$/ && ++n == 2 { f = 1 }' "$MD")
MDX=$(printf '%s\n' "$BODY" | awk '
  /^- \*\*Direct modules\*\*: / { s = $0; sub(/^- \*\*Direct modules\*\*: /, "", s); split(s, a, " "); print "direct " a[1]
    s = $0; sub(/.*\*\*Indirect modules\*\*: /, "", s); split(s, a, " "); print "indirect " a[1] }
  /^- \*\*Overall risk\*\*: \*\*/ { s = $0; sub(/^- \*\*Overall risk\*\*: \*\*/, "", s); sub(/\*\*.*/, "", s); print "level " s }')
cmp_set "impact.md counts and overall risk match the JSON" "$(printf 'direct %s\nindirect %s\nlevel %s' "$(X .direct)" "$(X .indirect)" "$(X .level)")" "$MDX"
SEC3=$(printf '%s\n' "$BODY" | awk '/^## 3\. / { f = 1; next } /^### Investigated/ { f = 0 } /^## 4\. / { f = 0 } f')
cmp_set "impact.md §3 lists exactly the JSON's modules" "$(X '.modules[]' | set_of)" "$(printf '%s\n' "$SEC3" | grep -oE '^(- |\| )\*\*[a-z0-9][a-z0-9-]*\*\*' | sed 's/^[-|] \*\*//; s/\*\*$//' | set_of)"
cmp_set "impact.md §9 lists exactly the JSON's risks" "$(X '.risks[]' | set_of)" "$(printf '%s\n' "$BODY" | grep -oE '^\| R[SA]-[0-9]{2,} \|' | tr -d '| ' | set_of)"
cmp_set "impact.md §10 lists exactly the JSON's QA scenarios" "$(X '.scenarios[]' | set_of)" "$(printf '%s\n' "$BODY" | grep -oE '^\| QA-[0-9]{2,} \|' | tr -d '| ' | set_of)"
cmp_set "impact.md §11 lists exactly the JSON's open questions and assumptions" "$(X '.questions[], .assumptions[]' | set_of)" "$(printf '%s\n' "$BODY" | grep -oE '^- \*\*[QA][0-9]+\*\*' | sed 's/^- \*\*//; s/\*\*$//' | set_of)"
hid() { grep -oE "id=\"$1-[^\"]+\"" "$HT" | sed "s/^id=\"$1-//; s/\"\$//" | set_of; }
HTX=$(printf 'direct %s\nindirect %s\nlevel %s' "$(grep -oE 'data-count="direct">[0-9]+<' "$HT" | grep -oE '[0-9]+' | head -1)" \
  "$(grep -oE 'data-count="indirect">[0-9]+<' "$HT" | grep -oE '[0-9]+' | head -1)" "$(grep -oE 'data-risk-level="[A-Za-z]+"' "$HT" | head -1 | cut -d'"' -f2)")
cmp_set "impact-report.html counts and overall risk match the JSON" "$(printf 'direct %s\nindirect %s\nlevel %s' "$(X .direct)" "$(X .indirect)" "$(X .level)")" "$HTX"
cmp_set "impact-report.html has exactly the JSON's modules" "$(X '.modules[]' | set_of)" "$(hid mod)"
cmp_set "impact-report.html has exactly the JSON's risks" "$(X '.risks[]' | set_of)" "$(hid risk)"
cmp_set "impact-report.html has exactly the JSON's QA scenarios" "$(X '.scenarios[]' | set_of)" "$(hid qa)"
cmp_set "impact-report.html has exactly the JSON's open questions" "$(X '.questions[]' | set_of)" "$(hid q)"
cmp_set "impact-report.html has exactly the JSON's assumptions" "$(X '.assumptions[]' | set_of)" "$(hid a)"
grep -q 'data-status="Draft"' "$HT" && ! grep -qE 'data-status="(Reviewed|Approved)"' "$HT" && ok "status Draft (impact-report.html)" || fail "status Draft (impact-report.html)"

# ---- 4. HTML self-contained and safe
NSCRIPT=$(grep -oi '<script' "$HT" | grep -c .)
[ "$NSCRIPT" = 2 ] && ok "exactly 2 script elements (data + app)" || fail "exactly 2 script elements (data + app)" "found $NSCRIPT: data must be escaped, never a <script>"
awk '/^<script>$/ { f = 1 } f { print } /^<\/script>$/ { f = 0 }' "$HT" > "$TMPD/app.js"
awk '/^<script>$/ { f = 1 } f { print } /^<\/script>$/ { f = 0 }' "$ATREYA_LIB/impact-report.html" > "$TMPD/tpl.js"
[ -s "$TMPD/app.js" ] && cmp -s "$TMPD/app.js" "$TMPD/tpl.js" && ok "app script is the template's, unchanged" || fail "app script is the template's, unchanged"
STYLE_OK=$(awk '/^<style>$/ { f = 1 } f { print } /^<\/style>$/ { f = 0 }' "$HT" | cmp -s - <(awk '/^<style>$/ { f = 1 } f { print } /^<\/style>$/ { f = 0 }' "$ATREYA_LIB/impact-report.html") && echo y)
[ "$STYLE_OK" = y ] && ok "stylesheet is the template's, unchanged" || fail "stylesheet is the template's, unchanged"
grep -o '<script type="application/json" id="atreya-data">.*</script>' "$HT" | sed 's#^<script type="application/json" id="atreya-data">##; s#</script>$##' > "$TMPD/data.json"
"$JQ" -e '.modules | type == "array"' "$TMPD/data.json" >/dev/null 2>&1 && ok "embedded map data is valid JSON" || fail "embedded map data is valid JSON"
grep -q "http-equiv=\"Content-Security-Policy\" content=\"default-src 'none';" "$HT" && ok "CSP blocks every external request" || fail "CSP blocks every external request"
EXT=$(grep -oiE '(src|href|action|xlink:href|poster|srcset)[[:space:]]*=[[:space:]]*"[[:space:]]*(https?:|//|ftp:|data:text/html|javascript:)[^"]*"|url\([[:space:]]*["'"'"']?[[:space:]]*(https?:|//)[^)]*\)|@import' "$HT" | head -5)
[ -z "$EXT" ] && ok "no external URL (src/href/action/url()/@import)" || fail "no external URL (src/href/action/url()/@import)" "$EXT"
# only real tags count: escaped text (&lt;img onerror=…) is harmless and stays text
TAGS=$( { grep -oiE '<(iframe|object|embed|link|img|base|form|meta http-equiv="refresh"|svg|math|template)[ >]' "$HT"
          grep -oE '<[a-zA-Z][^>]*>' "$HT" | grep -oiE '[[:space:]"]on[a-z]+[[:space:]]*=' ; } | sort -u | head -5)
[ -z "$TAGS" ] && ok "no injected tags or inline event handlers" || fail "no injected tags or inline event handlers" "$TAGS"

# ---- 5. secrets
"$JQ" -r '.. | strings' "$FJ" > "$TMPD/strings.txt"   # decoded values (JSON escaping hides them from line patterns)
SEC=$(secret_scan "$FJ" "$MD" "$HT" "$TMPD/strings.txt" | cut -f1-3)
[ -z "$SEC" ] && ok "no key-like strings (json, md, html)" || fail "no key-like strings (json, md, html)" "$(printf '%s\n' "$SEC" | sed "s#$DIR/##; s/\t/: /g")"

if [ "$SUM" = 1 ]; then
  echo
  "$JQ" -r -L "$ATREYA_LIB" --arg md "$MD" --arg ht "$HT" --arg warns "$WARNS" '
    include "impact-view"; view as $V |
    "## Impact summary: \($V.ticket)",
    "- Change: \($V.title)\(if $V.input.source == "zoho" then " (Zoho Sprints \($V.input.id))" else " (free text)" end)",
    "- Changed module(s): \($V.changed_modules | join(", ") | if . == "" then "none" else . end)",
    "- Affected modules: \($V.counts.direct) direct, \($V.counts.indirect) indirect" +
      ([$V.modules[] | select(.role == "indirect") | "\(.id) (\(.direction), depth \(.depth // "?"))"] | if length > 0 then ": " + join(", ") else "" end),
    "- Overall risk: \($V.risk.level) (confidence \($V.risk.confidence)); script rules \($V.risk.script_level)\(if ($V.risk.raised_by | length) > 0 then ", raised by \($V.risk.raised_by | join(", "))" else "" end)",
    "- Missing information: \($V.open_questions | length) open question(s)\(if ($V.open_questions | length) > 0 then " (" + ([$V.open_questions[] | "\(.id) \(.role)"] | join(", ")) + ")" else "" end), \(($V.requirement.missing // []) | length) missing requirement(s), \($V.assumptions | length) assumption(s), \([$V.unknowns[] | select(.generic != true)] | length) unknown link(s), \($V.conflicts | length) conflict(s)",
    "- Reports: \($md)", "           \($ht)",
    "- check-doc warnings: \($warns)"' "$FJ"
fi
echo
if [ $FAILS = 0 ] && [ "$FINAL" = 1 ] && [ -f "$DIR/.analysis-draft.json" ]; then
  rm -f "$DIR/.analysis-draft.json" && echo "removed the analysis draft (it is merged into impact-facts.json)"
fi
[ $FAILS = 0 ] && { echo "impact-check: PASS ($DIR)"; exit 0; } || { echo "impact-check: $FAILS check(s) failed ($DIR)"; exit 1; }
