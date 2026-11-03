#!/bin/bash
# impact-render.sh [--root R] --ticket T [--analysis DRAFT.json] [--dir DIR]
#
# Renders impact.md and impact-report.html from ONE source: impact-facts.json
# (atreya-docs/dev/T/, or --dir). With --analysis, first checks Claude's analysis
# (references/impact-facts-schema.md) and merges it under "analysis":
#   - schema, ids, evidence classes (scripts/lib/impact-validate.jq)
#   - every Verified Repo:path:line exists (tracked, not secret, line not blank)
#   - QA results only with a QA report file that exists; requirement IDs exist
#   - no key-like strings in the draft
#   - the script facts are untouched (facts_sha256); status is forced to Draft
# Nothing is written unless every check passes (temp files, then mv).
# impact.md: front matter from doc-stamp.sh + the 12 template headings
# (lib/impact-md.jq). impact-report.html: lib/impact-report.html (static CSS/JS)
# + lib/impact-html.jq parts, all text HTML-escaped; one file, no external requests.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
SLUG=""; DRAFT=""; DIR=""
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do case "$1" in
  --ticket) SLUG="$2"; shift 2 ;; --analysis) DRAFT="$2"; shift 2 ;; --dir) DIR="$2"; shift 2 ;;
  *) die "unknown argument $1" ;; esac; done
case "$SLUG" in ""|*[!A-Za-z0-9._-]*|.*) die "usage: impact-render.sh --root R --ticket T [--analysis DRAFT.json] [--dir DIR]" ;; esac
[ -n "$DIR" ] || DIR="$DOCS/dev/$SLUG"
FACTS="$DIR/impact-facts.json"
[ -f "$FACTS" ] || die "no $FACTS (run impact-facts.sh first)"
"$JQ" -e '.schema == "atreya.impact/2"' "$FACTS" >/dev/null 2>&1 || die "$FACTS is not schema atreya.impact/2 (re-run impact-facts.sh)"
"$JQ" -e --arg t "$SLUG" '.ticket == $t' "$FACTS" >/dev/null || die "$FACTS belongs to another ticket"
SHA=$("$JQ" -S -c 'del(.analysis, .review, .facts_sha256)' "$FACTS" | shasum -a 256 | cut -d' ' -f1)
[ "$SHA" = "$("$JQ" -r '.facts_sha256' "$FACTS")" ] || die "the script facts in $FACTS were edited (facts_sha256 differs); re-run impact-facts.sh"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atreya-render.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT

# ---- check and merge the analysis
if [ -n "$DRAFT" ]; then
  [ -f "$DRAFT" ] || die "no analysis file $DRAFT"
  "$JQ" -e 'type == "object"' "$DRAFT" >/dev/null 2>&1 || die "$DRAFT is not a JSON object"
  ERRS=""
  # scan the decoded strings too: JSON escaping (\") hides values from the line patterns
  "$JQ" -r '.. | strings' "$DRAFT" > "$TMPD/strings.txt"
  SEC=$( { secret_scan "$DRAFT"; secret_scan "$TMPD/strings.txt"; } | cut -f2,3)
  [ -z "$SEC" ] || ERRS="${ERRS}key-like string in the analysis (line: type): $(printf '%s' "$SEC" | tr '\t\n' ': ')
"
  MODIDS=$(bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml" | "$JQ" -c '[.modules[].id]') || die "modules.yaml does not parse"
  "$JQ" --slurpfile Af "$DRAFT" --argjson modids "$MODIDS" -L "$ATREYA_LIB" -f "$ATREYA_LIB/impact-validate.jq" "$FACTS" > "$TMPD/v.json" \
    || die "analysis check failed (bug)"
  ERRS="$ERRS$("$JQ" -r '.errors[]' "$TMPD/v.json")
"
  while IFS= read -r c; do [ -n "$c" ] || continue
    p=$(cite_problem "$c"); [ -z "$p" ] || ERRS="${ERRS}Verified citation does not hold: $p
"
  done <<EOF
$("$JQ" -r '.cites[]' "$TMPD/v.json")
EOF
  while IFS= read -r r; do [ -n "$r" ] || continue
    case "$r" in /*|*..*) ERRS="${ERRS}QA report $r: give a path relative to the workspace, inside atreya-docs/ or atreya-qa/
"; continue ;; esac
    case "$r" in atreya-docs/*|atreya-qa/*) [ -f "$ROOT/$r" ] || ERRS="${ERRS}QA report $r does not exist
" ;; *) ERRS="${ERRS}QA report $r must be inside atreya-docs/ or atreya-qa/
" ;; esac
  done <<EOF
$("$JQ" -r '.reports[]' "$TMPD/v.json")
EOF
  KNOWN=$("$JQ" -r '.traceability[].ref, .qa_scope.existing[].ref' "$FACTS")
  while IFS= read -r ref; do [ -n "$ref" ] || continue
    printf '%s\n' "$KNOWN" | grep -qxF -- "$ref" && continue
    grep -qE -- "^### $ref([^0-9]|$)|^\| *$ref *\|" "$DOCS"/nt/*/PRD.md "$DOCS"/nt/*/BRD.md 2>/dev/null && continue
    ERRS="${ERRS}requirement $ref is not in the facts' traceability nor defined in any nt/<module>/PRD.md or BRD.md
"
  done <<EOF
$("$JQ" -r '.refs[]' "$TMPD/v.json")
EOF
  ERRS=$(printf '%s' "$ERRS" | grep .)
  if [ -n "$ERRS" ]; then
    printf 'impact-render: the analysis has %d problem(s); nothing was written:\n' "$(printf '%s\n' "$ERRS" | grep -c .)" >&2
    printf '%s\n' "$ERRS" | sed 's/^/  - /' >&2
    exit 1
  fi
  "$JQ" --slurpfile A "$DRAFT" '.analysis = $A[0] | .review = ((.review // {}) + {status: "Draft"})' "$FACTS" > "$TMPD/facts.json" || die "merge failed (bug)"
else
  "$JQ" -e '.analysis | type == "object"' "$FACTS" >/dev/null || die "no analysis in $FACTS yet: give --analysis DRAFT.json"
  "$JQ" '.review = ((.review // {}) + {status: "Draft"})' "$FACTS" > "$TMPD/facts.json"
fi

# ---- impact.md
IDS=$("$JQ" -r '([.modules[] | select(.role == "direct") | .id] | if length > 0 then . else [] end) as $d |
  (if ($d | length) > 0 then $d else [.modules[] | .id] end) | join(",")' "$TMPD/facts.json")
[ -n "$IDS" ] || die "no module matched the seeds (risk TBD): check the seeds and re-run impact-facts.sh"
STAMP=$(bash "$ATREYA_SCRIPTS/doc-stamp.sh" --root "$ROOT" "$IDS" impact "$SLUG") || die "doc-stamp failed"
{ printf '%s\n' "$STAMP"; "$JQ" -r -L "$ATREYA_LIB" -f "$ATREYA_LIB/impact-md.jq" "$TMPD/facts.json" | redact; } > "$TMPD/impact.md" \
  || die "impact.md rendering failed (bug)"

# ---- impact-report.html (template lines <!--ATREYA:HEAD|BODY|DATA--> replaced by the rendered parts)
for p in head body data; do
  "$JQ" -r -L "$ATREYA_LIB" --arg part "$p" -f "$ATREYA_LIB/impact-html.jq" "$TMPD/facts.json" > "$TMPD/$p.html" || die "impact-report.html $p failed (bug)"
done
awk -v hf="$TMPD/head.html" -v bf="$TMPD/body.html" -v df="$TMPD/data.html" '
  function cat(f,   l) { while ((getline l < f) > 0) print l; close(f) }
  $0 == "<!--ATREYA:HEAD-->" { cat(hf); next }
  $0 == "<!--ATREYA:BODY-->" { cat(bf); next }
  $0 == "<!--ATREYA:DATA-->" { cat(df); next }
  { print }' "$ATREYA_LIB/impact-report.html" > "$TMPD/impact-report.html" || die "impact-report.html assembly failed"

mkdir -p "$DIR" || die "cannot create $DIR"
mv "$TMPD/facts.json" "$FACTS" && mv "$TMPD/impact.md" "$DIR/impact.md" && mv "$TMPD/impact-report.html" "$DIR/impact-report.html" || die "could not write to $DIR"
"$JQ" -r '"impact-render: \(.ticket): \([.modules[] | select(.role == "direct")] | length) direct + \([.modules[] | select(.role == "indirect")] | length) indirect modules, \(.risks | length) script + \((.analysis.risks // []) | length) analysis risks, \((.analysis.qa_scenarios // []) | length) QA scenarios, \((.analysis.open_questions // []) | length) open questions"' "$FACTS"
echo "wrote $DIR/impact.md and $DIR/impact-report.html"
