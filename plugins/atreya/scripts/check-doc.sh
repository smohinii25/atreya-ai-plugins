#!/bin/bash
# check-doc.sh [--root R] DOC.md
#
# Mechanical checks of a BRD/PRD (the doc-checker agent then checks meaning):
#   1. front matter parses; module/doc/status/date/reviewer/commits present;
#      status is Draft, Reviewed or Approved
#   2. the "## N. Title" headings are exactly the template's, in order
#   3. PRD: requirement IDs <MODULE>-Rnn unique, each with "Acceptance criteria"
#      and a "Source" citation; BRD: BR-nn unique
#   4. every cited `Repo:path:line` exists (tracked file, line within the file);
#      lines may be a list and/or ranges (:12,40-55): a range must run forward
#      and end inside the file. A cited line (first line of a range) that is
#      blank fails; one holding only a brace/bracket is a warning.
#      Short citations (`File.php:12`, `:12`) cannot be checked: warning.
#   5. no key-like strings (shared redaction patterns, scan mode)
#   6. a "Needs confirmation" / "Open questions" section with content or "None"
# Prints PASS/FAIL per check (and WARN lines, which do not fail); exit 1 if any FAIL.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
F="${ARGS[0]:-}"; [ -f "$F" ] || die "usage: check-doc.sh --root R DOC.md"
FAILS=0
ok()   { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; [ -n "$2" ] && printf '%s\n' "$2" | grep . | head -20 | sed 's/^/        /'; FAILS=$((FAILS+1)); }
warn_() { echo "WARN  $1"; [ -n "$2" ] && printf '%s\n' "$2" | grep . | head -20 | sed 's/^/        /'; }

# split_cites: one citation per line (a diagram source may hold several, "; "-separated).
# A function, not inline: bash 3.2 misparses ")" inside $( ) within a case branch.
split_cites() { awk '{ n = split($0, a, "; "); for (i = 1; i <= n; i++) print a[i] }'; }

# check_cites "LIST" -> every Repo:path[:lines] in LIST exists and points at code
# (shared by docs and diagrams)
check_cites() {
  local c repo rest path lines n bad="" weak="" count=0 part a b t
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    repo=${c%%:*}; rest=${c#*:}; [ -d "$ROOT/repos/$repo" ] || continue
    count=$((count+1)); path=${rest%%:*}; lines=""; [ "$rest" != "$path" ] && lines=${rest#*:}
    if ! git -C "$ROOT/repos/$repo" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then bad="$bad$c (file not tracked)
"; continue; fi
    [ -n "$lines" ] || continue
    n=$(wc -l < "$ROOT/repos/$repo/$path" | tr -d ' ')
    for part in $(printf '%s' "$lines" | tr ',' ' '); do
      a=${part%%-*}; b=${part#*-}
      case "$a$b" in ""|*[!0-9]*) bad="$bad$c (cannot read the line numbers)
"; continue ;; esac
      if [ "$a" -gt "$b" ]; then bad="$bad$c (range $part runs backwards)
"; continue; fi
      if [ "$b" -gt "$((n + 1))" ]; then bad="$bad$c (file has $n lines)
"; continue; fi
      t=$(sed -n "${a}p" "$ROOT/repos/$repo/$path" | tr -d ' \t\r')
      if [ -z "$t" ]; then bad="$bad$c (line $a is blank)
"
      else case "$t" in '}'|'{'|')'|');'|'};'|'});'|']'|'];'|']);'|'],'|'},'|'),') weak="$weak$c (line $a holds only $t)
" ;; esac; fi
    done
  done <<EOF
$1
EOF
  [ -z "$bad" ] && ok "all $count code citations exist" || fail "code citations exist" "$bad"
  [ -z "$weak" ] || warn_ "cited lines that hold only a brace (check the line number)" "$weak"
}

# ---------------------------------------------------------------- diagrams
case "$F" in *.drawio)
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$F" 2>/dev/null && ok "well-formed XML" || fail "well-formed XML"
  fi
  STAMP=$(grep -o '<UserObject id="atreya-stamp"[^>]*>' "$F" | head -n 1)
  case "$STAMP" in *atreya_module=\"?*\"*atreya_commits=\"?*\"*) ok "stamp present (module, commits)" ;; *) fail "stamp present (module, commits)" ;; esac
  OBJ=$(grep -o '<UserObject [^>]*>' "$F" | grep -v 'id="atreya-\(stamp\|title\)"')
  NOSRC=$(printf '%s\n' "$OBJ" | grep -v 'atreya_type="external"' | grep -E 'atreya_source=""|^[^a]*$' | grep -o 'label="[^"]*"' | head -20)
  [ -z "$NOSRC" ] && ok "every box and arrow has a source ($(printf '%s\n' "$OBJ" | grep -c .) elements)" || fail "every box and arrow has a source" "$NOSRC"
  check_cites "$(printf '%s\n' "$OBJ" | grep -o 'atreya_source="[^"]*"' | sed 's/^atreya_source="//; s/"$//' | split_cites | sort -u)"
  SEC=$(secret_scan "$F" | cut -f2,3)
  [ -z "$SEC" ] && ok "no key-like strings" || fail "no key-like strings" "$(printf '%s\n' "$SEC" | sed 's/\t/: /')"
  [ $FAILS = 0 ] && { echo "check-doc: PASS ($F)"; exit 0; } || { echo "check-doc: $FAILS check(s) failed ($F)"; exit 1; }
;; esac

FM=$(bash "$ATREYA_SCRIPTS/yaml2json.sh" --front-matter "$F" 2>&1) && ok "front matter parses" || { fail "front matter parses" "$FM"; FM='{}'; }
MISSING=$(printf '%s' "$FM" | "$JQ" -r '[("module","doc","status","date","reviewer","commits") as $k | select(has($k) | not) | $k] | join(", ")' 2>/dev/null)
[ -z "$MISSING" ] && ok "stamp fields present" || fail "stamp fields present" "missing: $MISSING"
STATUS=$(printf '%s' "$FM" | "$JQ" -r '.status // ""'); DOC=$(printf '%s' "$FM" | "$JQ" -r '.doc // ""'); MOD=$(printf '%s' "$FM" | "$JQ" -r '.module // ""')
case "$STATUS" in Draft|Reviewed|Approved) ok "status is $STATUS" ;; *) fail "status Draft/Reviewed/Approved" "got: $STATUS" ;; esac

case "$DOC" in PRD) TPL="$ATREYA_PLUGIN/references/prd-template.md" ;; BRD) TPL="$ATREYA_PLUGIN/references/brd-template.md" ;;
  impact) TPL="$ATREYA_PLUGIN/references/impact-template.md" ;; *) TPL="" ;; esac
if [ -n "$TPL" ]; then
  WANT=$(grep -E '^## [0-9]+\. ' "$TPL"); GOT=$(grep -E '^## [0-9]+\. ' "$F")
  [ "$WANT" = "$GOT" ] && ok "headings match the $DOC template ($(printf '%s\n' "$WANT" | grep -c .) sections)" \
    || fail "headings match the $DOC template" "$(diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | grep '^[<>]')"
fi

if [ "$DOC" = PRD ] && [ -n "$MOD" ]; then
  P=$(printf '%s' "$MOD" | tr '[:lower:]' '[:upper:]')
  IDS=$(grep -oE "^### $P-R[0-9]{2,}" "$F" | sed 's/^### //')
  DUP=$(printf '%s\n' "$IDS" | sort | uniq -d)
  [ -n "$IDS" ] && [ -z "$DUP" ] && ok "requirement IDs $P-Rnn unique ($(printf '%s\n' "$IDS" | grep -c .))" || fail "requirement IDs $P-Rnn present and unique" "${DUP:-no ### $P-Rnn headings}"
  BAD=$(awk -v p="### $P-R" '
    index($0, p) == 1 { if (id != "" && (!ac || !src)) print id; id = $2; ac = 0; src = 0; next }
    /^## / { if (id != "" && (!ac || !src)) print id; id = "" }
    id != "" && tolower($0) ~ /acceptance criteria/ { ac = 1 }
    id != "" && /[Ss]ource/ && /`[A-Za-z0-9_.-]+:[^`]+`/ { src = 1 }
    END { if (id != "" && (!ac || !src)) print id }' "$F")
  [ -z "$BAD" ] && ok "every requirement has acceptance criteria and a cited source" || fail "every requirement has acceptance criteria and a cited source" "$BAD"
fi
if [ "$DOC" = BRD ]; then
  IDS=$(grep -oE '\bBR-[0-9]{2,}\b' "$F" | sort); DUP=$(grep -oE '^(###|\|) *BR-[0-9]{2,}' "$F" | grep -oE 'BR-[0-9]+' | sort | uniq -d)
  [ -n "$IDS" ] && [ -z "$DUP" ] && ok "BR-nn IDs present and defined once" || fail "BR-nn IDs present and defined once" "${DUP:-none found}"
fi

# citations: `Repo:path` or `Repo:path:line` (line may be a,b,c)
check_cites "$(grep -oE '`[A-Za-z0-9_.-]+:[A-Za-z0-9_./{}@-]+(:[0-9]+([,-][0-9]+)*)?`' "$F" | tr -d '`' | sort -u)"
# short citations: a file or a bare line number without the repo cannot be checked
SHORT=$( { grep -oE '`[A-Za-z0-9_./-]+\.(php|dart|js|ts|vue|py):[0-9]+([,-][0-9]+)*`' "$F"; grep -oE '`:[0-9]+([,-][0-9]+)*`' "$F"; } | tr -d '`' | sort -u |
  while IFS= read -r c; do p=${c%%:*}; [ -n "$p" ] && [ -d "$ROOT/repos/$p" ] && continue; printf '%s\n' "$c"; done)
[ -z "$SHORT" ] || warn_ "$(printf '%s\n' "$SHORT" | grep -c .) citation(s) without the repo cannot be checked; write Repo:path:line" "$SHORT"

SEC=$(secret_scan "$F" | cut -f2,3)
[ -z "$SEC" ] && ok "no key-like strings" || fail "no key-like strings" "$(printf '%s\n' "$SEC" | sed 's/\t/: /')"

NC_SEC=$(awk 'tolower($0) ~ /^## [0-9]+\. (needs confirmation|open questions)/ { f = 1; next } /^## / { f = 0 } f && NF' "$F" | grep -c .)
[ "$NC_SEC" -gt 0 ] && ok "Needs confirmation / Open questions section is filled ($NC_SEC lines)" || fail "Needs confirmation / Open questions section is filled" "write the open items, or \"None.\""

[ $FAILS = 0 ] && { echo "check-doc: PASS ($F)"; exit 0; } || { echo "check-doc: $FAILS check(s) failed ($F)"; exit 1; }
