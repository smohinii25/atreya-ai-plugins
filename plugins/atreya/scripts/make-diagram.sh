#!/bin/bash
# make-diagram.sh [--root R] MODULE KIND [diagram-spec options]
# make-diagram.sh [--root R] MODULE --rerun NAME
#
# One diagram end to end: diagram-spec.sh -> <name>.spec.json, drawio.sh ->
# <name>.drawio, check-doc.sh on the result. Writes into
# atreya-docs/nt/<module>/diagrams/. Re-running on the same commit gives
# byte-identical files (the date in the stamp is the only day-dependent part).
# --rerun NAME regenerates an existing diagram with the kind and options saved
# in NAME.spec.json, so a refresh repeats exactly what was asked the first time.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
ID="${ARGS[0]:-}"; KIND="${ARGS[1]:-}"
[ -n "$ID" ] && [ -n "$KIND" ] || die "usage: make-diagram.sh --root R MODULE er|sequence|flow [options] | MODULE --rerun NAME"
OUTD="$DOCS/nt/$ID/diagrams"; mkdir -p "$OUTD" || die "cannot create $OUTD"
RERUN=""
if [ "$KIND" = "--rerun" ]; then
  RERUN="${ARGS[2]:-}"
  case "$RERUN" in ""|*[!A-Za-z0-9._-]*) die "usage: make-diagram.sh --root R MODULE --rerun NAME" ;; esac
  OLD="$OUTD/$RERUN.spec.json"; [ -f "$OLD" ] || die "no $OLD"
  "$JQ" -e 'has("options")' "$OLD" >/dev/null 2>&1 || die "$RERUN.spec.json has no saved options (made before they were recorded): regenerate it with explicit options"
  KIND=$("$JQ" -r '.kind' "$OLD")
  ARGS=("$ID" "$KIND")
  while IFS=$'\t' read -r k v; do ARGS+=("--$k" "$v"); done < <("$JQ" -r '.options | to_entries[] | "\(.key)\t\(.value)"' "$OLD")
fi
TMP=$(mktemp "${TMPDIR:-/tmp}/atreya-spec.XXXXXX") || die "mktemp failed"
trap 'rm -f "$TMP"' EXIT
bash "$ATREYA_SCRIPTS/diagram-spec.sh" --root "$ROOT" "${ARGS[@]}" > "$TMP" || exit 1
NAME=$("$JQ" -r '.name' "$TMP")
case "$NAME" in ""|*[!A-Za-z0-9._-]*) die "bad diagram name '$NAME'" ;; esac
[ -z "$RERUN" ] || [ "$NAME" = "$RERUN" ] || die "saved options of $RERUN make a diagram named $NAME (bug)"
cp "$TMP" "$OUTD/$NAME.spec.json"
bash "$ATREYA_SCRIPTS/drawio.sh" "$OUTD/$NAME.spec.json" "$OUTD/$NAME.drawio" || exit 1
bash "$ATREYA_SCRIPTS/check-doc.sh" --root "$ROOT" "$OUTD/$NAME.drawio" | tail -n 1
