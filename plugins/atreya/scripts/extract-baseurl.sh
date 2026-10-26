#!/bin/bash
# extract-baseurl.sh [--root R] [REPO]   (default REPO: Nadi-Tarangini-App)
#
# THE ONLY atreya script allowed to read a guarded file. flavor_config.dart
# holds the app's baseUrl per environment AND (commented-out) payment keys, so
# the guard blocks Claude from reading it. This script prints ONLY:
#   {"file": "...", "baseUrl": {"<env>": "<https url>", ...}}
# Every value passes the shared redaction filter and must look like a plain
# https URL; anything else is dropped. No other line of the file is output.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-Nadi-Tarangini-App}")

# Tracked copies only, found by name (unfiltered on purpose: this is the exception).
FILES=$(git -C "$REPO" ls-files | awk '{ n = $0; sub(/.*\//, "", n); if (tolower(n) == "flavor_config.dart") print }')
[ -n "$FILES" ] || die "no tracked flavor_config.dart in $REPO"
[ "$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')" = 1 ] || die "more than one flavor_config.dart in $REPO; refusing to guess"

# env<TAB>url for each `baseUrl = "..."` under `case Environment.<env>:`,
# skipping commented lines. Nothing else is printed.
PAIRS=$(awk '
  /^[ \t]*\/\// { next }
  match($0, /case[ \t]+Environment\.[A-Za-z_]+/) { env = substr($0, RSTART, RLENGTH); sub(/.*\./, "", env); next }
  /^[ \t]*baseUrl[ \t]*=[ \t]*["\047]/ {
    v = $0; sub(/^[ \t]*baseUrl[ \t]*=[ \t]*["\047]/, "", v); sub(/["\047].*$/, "", v)
    if (env != "") printf "%s\t%s\n", env, v
  }' "$REPO/$FILES" | redact)

OUT=$(printf '%s\n' "$PAIRS" | awk -F '\t' 'NF == 2 && $2 ~ /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]+)?(\/[A-Za-z0-9._~\/-]*)?$/ && $2 !~ /REDACTED/' \
  | "$JQ" -R -s --arg f "$FILES" '
      split("\n") | map(select(length > 0) | split("\t")) |
      {file: $f, baseUrl: (map({key: .[0], value: .[1]}) | from_entries)}')
DROPPED=$(( $(printf '%s\n' "$PAIRS" | grep -c . ) - $(printf '%s' "$OUT" | "$JQ" '.baseUrl | length') ))
[ "$DROPPED" -gt 0 ] && warn "$DROPPED baseUrl value(s) dropped (not a plain https URL)"
printf '%s\n' "$OUT"
