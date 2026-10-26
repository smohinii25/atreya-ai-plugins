#!/bin/bash
# staging-delta.sh [--root R] MODULE_ID
#
# What staging has that production doesn't, for one module, per repo:
#   git log --oneline <production ref>..<staging ref> -- <module paths>
#   git diff --stat   <production ref>..<staging ref> -- <module paths>
# Refs come ONLY from atreya-docs/environments.md (column "Ref"). A repo whose
# staging or production ref is empty or "TO FILL" is skipped with
# "waiting for environments.md"; a branch is never guessed. Read-only git;
# no patches are printed (names and counts only); secret files are excluded.
# Writes atreya-docs/nt/<id>/staging-delta.md (with the doc stamp).
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
ID="${ARGS[0]:-}"; [ -n "$ID" ] || die "usage: staging-delta.sh --root R MODULE_ID"
[ -f "$DOCS/modules.yaml" ] || die "no modules.yaml"
MJ=$(bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml") || exit 1
printf '%s' "$MJ" | "$JQ" -e --arg id "$ID" '.modules | any(.id == $id)' >/dev/null || die "unknown module $ID"
OUT="$DOCS/nt/$ID/staging-delta.md"; mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"
ENV="$DOCS/environments.md"

ref_of() {  # ref_of REPO ENV -> the Ref cell, or empty
  [ -f "$ENV" ] || return 0
  awk -v repo="$1" -v env="$2" '
    /^## / { cur = substr($0, 4) }
    cur == repo && /^\|/ { line = $0; gsub(/^\| *| *\|$/, "", line); n = split(line, a, / *\| */)
      if (a[1] == "Env") { for (i = 1; i <= n; i++) if (a[i] == "Ref") col = i; next }
      if (a[1] == env && col) { print a[col]; exit } }' "$ENV"
}
NOSEC=(':!*.env' ':!*.env.*' ':!*.jks' ':!*.keystore' ':!*firebase-*.json' ':!*google-services.json' ':!*GoogleService-Info.plist' ':!*gchat_logger.dart' ':!*flavor_config.dart' ':!*SamvitPaymentBridgeController.php' ':(exclude).env.example')

{
  bash "$ATREYA_SCRIPTS/doc-stamp.sh" --root "$ROOT" "$ID" staging-delta
  echo "# $(printf '%s' "$MJ" | "$JQ" -r --arg id "$ID" '.modules[] | select(.id == $id) | .name'): staging delta"
  echo
  echo "What staging has that production doesn't, on this module's files. Refs come only from \`environments.md\`."
  echo
  printf '%s' "$MJ" | "$JQ" -r --arg id "$ID" '.modules[] | select(.id == $id) | .repos[] | "\(.repo)\t\(.files | join("\u001f"))"' |
  while IFS='	' read -r repo files; do
    echo "## $repo"
    echo
    st=$(ref_of "$repo" staging); pr=$(ref_of "$repo" production)
    case "$st$pr" in *"TO FILL"*) st="" ;; esac
    if [ -z "$st" ] || [ -z "$pr" ]; then
      echo "Skipped: **waiting for environments.md** (staging and production refs for $repo are not filled in)."; echo; continue
    fi
    d=$(repo_dir "$repo")
    if ! git -C "$d" rev-parse --verify -q "$st^{commit}" >/dev/null || ! git -C "$d" rev-parse --verify -q "$pr^{commit}" >/dev/null; then
      echo "Skipped: ref \`$st\` or \`$pr\` not found locally (a human may need to run \`git fetch\`)."; echo; continue
    fi
    IFS=$'\037' read -r -a PS <<< "$files"
    [ ${#PS[@]} -gt 0 ] || { echo "No module files in this repo."; echo; continue; }
    echo "Production \`$pr\` ($(git -C "$d" rev-parse --short "$pr")) → staging \`$st\` ($(git -C "$d" rev-parse --short "$st"))"
    echo
    n=$(git -C "$d" log --oneline "$pr..$st" -- "${PS[@]}" "${NOSEC[@]}" | grep -c .)
    echo "### Commits only on staging ($n)"
    echo
    if [ "$n" = 0 ]; then echo "None."; else git -C "$d" log --format='- `%h` %ad %s' --date=short "$pr..$st" -- "${PS[@]}" "${NOSEC[@]}" | head -n 200 | redact; fi
    echo
    echo "### Files changed"
    echo
    s=$(git -C "$d" diff --stat=200 "$pr..$st" -- "${PS[@]}" "${NOSEC[@]}" | redact)
    if [ -z "$s" ]; then echo "None."; else printf '```\n%s\n```\n' "$s"; fi
    echo
  done
} > "$OUT"
echo "wrote $OUT"
grep -c 'waiting for environments.md' "$OUT" | awk '{ print "repos waiting for environments.md: " $1 }'
