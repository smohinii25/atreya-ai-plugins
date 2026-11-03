#!/bin/bash
# compat-otp-example.sh [WORKSPACE_ROOT]
#
# Backward compatibility on the REAL workspace: re-runs impact-facts.sh with the
# seeds stored in atreya-docs/dev/adhoc-otp-attempt-limit/impact-facts.json and
# checks that the same direct modules, related modules and backend routes come
# out as before. Writes only to a throwaway folder (--out under $TMPDIR); the
# example itself is never changed. Reads _map/ and modules.yaml, and runs
# git ls-files / rev-parse on the seed repos (names and hashes only, no contents).
# Skips (exit 0) when the workspace or the example is missing.
HERE=$(cd "$(dirname "$0")" && pwd -P)
S=$(cd "$HERE/../scripts" && pwd -P)
ROOT="${1:-${ATREYA_ROOT:-$HOME/Mohini/atreya-ai}}"
EX="$ROOT/atreya-docs/dev/adhoc-otp-attempt-limit/impact-facts.json"
[ -f "$EX" ] || { echo "skip: $EX not found (pass your workspace root: bash $0 /path/to/atreya-ai)"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/atreya-compat.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
PASSN=0; FAILN=0
expect_eq() { if [ "$2" = "$3" ]; then PASSN=$((PASSN+1)); printf 'PASS  %s\n' "$1"; else FAILN=$((FAILN+1)); printf 'FAIL  %s\n        expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }

BEFORE=$(shasum < "$EX")
SEEDS=()
while IFS= read -r a; do SEEDS+=("$a"); done < <(/usr/bin/jq -r '.seeds |
  (.files[] | "--file", "\(.repo):\(.path)\(if .line then ":\(.line)" else "" end)"), (.routes[] | "--route", .),
  (.tables[] | "--table", .), (.screens[] | "--screen", "\(.repo):\(.id)"), (.modules[] | "--module", .)' "$EX")
OUT=$(bash "$S/impact-facts.sh" --root "$ROOT" --ticket adhoc-otp-attempt-limit --out "$T/run" "${SEEDS[@]}" 2>&1) || { printf 'FAIL  impact-facts.sh runs\n%s\n' "$OUT"; exit 1; }
NEW="$T/run/impact-facts.json"
q() { /usr/bin/jq -r "$1" "$2"; }
expect_eq "same direct modules" "$(q '[.direct_modules[].id] | sort | join(",")' "$NEW")" "$(q '[.direct_modules[].id] | sort | join(",")' "$EX")"
expect_eq "same related modules" "$(q '[.related_modules[].id] | sort | join(",")' "$NEW")" "$(q '[.related_modules[].id] | sort | join(",")' "$EX")"
expect_eq "same backend routes" "$(q '[.backend_routes[].key] | sort | join(",")' "$NEW")" "$(q '[.backend_routes[].key] | sort | join(",")' "$EX")"
expect_eq "same client callers" "$(q '[.backend_routes[].callers[] | "\(.client) \(.caller)"] | sort | join(",")' "$NEW")" "$(q '[.backend_routes[].callers[] | "\(.client) \(.caller)"] | sort | join(",")' "$EX")"
expect_eq "same v1 risk level" "$(q '.risk.level' "$NEW")" "$(q '.risk.level' "$EX")"
expect_eq "v2 lists the direct module the same way" "$(q '[.modules[] | select(.role == "direct") | .id] | sort | join(",")' "$NEW")" "$(q '[.direct_modules[].id] | sort | join(",")' "$EX")"
expect_eq "the example itself is unchanged" "$(shasum < "$EX")" "$BEFORE"
printf 'info: v2 overall risk %s (rules %s); %s indirect, %s investigated-not-affected\n' \
  "$(q '.risk_overall.level' "$NEW")" "$(q '.risk_overall.rules | join(",")' "$NEW")" \
  "$(q '[.modules[] | select(.role == "indirect")] | length' "$NEW")" "$(q '.not_affected | length' "$NEW")"
printf '\n%d passed, %d failed\n' "$PASSN" "$FAILN"
[ $FAILN = 0 ]
