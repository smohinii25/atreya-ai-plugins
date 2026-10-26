#!/bin/bash
# routes-crosscheck.sh [--root R] REPO
#
# OPTIONAL cross-check of routes.json against `php artisan route:list --json`.
# Runs only if php and the repo's vendor/ exist, and only with a database
# connection that cannot connect (DB_CONNECTION=__atreya_no_db__), logs to
# stderr and array caches, so nothing touches a DB or writes into the repo.
# Prints the routes found by one side only. Never required by other scripts.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
RJ="$DOCS/_map/$NAME/routes.json"
[ -f "$RJ" ] || die "run routes.sh $NAME first"
command -v php >/dev/null 2>&1 || { echo "cross-check skipped: php not installed"; exit 0; }
[ -d "$REPO/vendor" ] || { echo "cross-check skipped: $NAME/vendor missing (composer install is blocked in repos/; static parse is the primary source)"; exit 0; }
OUT=$(cd "$REPO" && DB_CONNECTION=__atreya_no_db__ LOG_CHANNEL=stderr CACHE_DRIVER=array CACHE_STORE=array \
      SESSION_DRIVER=array QUEUE_CONNECTION=sync php artisan route:list --json 2>/dev/null) \
  || { echo "cross-check skipped: artisan route:list failed without a database"; exit 0; }
printf '%s' "$OUT" | "$JQ" -r --slurpfile s "$RJ" '
  [.[] | (.method | split("|") | map(select(. != "HEAD"))[]) as $m | "\($m) \(.uri | sub("^/"; ""))"] | unique as $a |
  [$s[0].routes[] | select(.shadowed | not) | .key | sub(" /$"; " /")] | unique as $b |
  "artisan: \($a | length) routes, static: \($b | length) routes",
  "only in artisan: \(($a - $b) | length)", (($a - $b)[0:30][] | "  + \(.)"),
  "only in static parse: \(($b - $a) | length)", (($b - $a)[0:30][] | "  - \(.)")'
