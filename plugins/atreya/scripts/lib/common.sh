#!/bin/bash
# Shared helpers for every atreya script. Source it:  . "$(dirname "$0")/lib/common.sh"
# Stock macOS only: bash 3.2, awk, git, /usr/bin/jq.
#
# Scripts are run by skills through the Bash tool, which does NOT receive the
# plugin's userConfig. So every script takes --root <workspace_root>; skills pass
# "${user_config.workspace_root}".

ATREYA_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ATREYA_SCRIPTS=$(dirname "$ATREYA_LIB")
ATREYA_PLUGIN=$(dirname "$ATREYA_SCRIPTS")
. "$ATREYA_LIB/redact.sh"
JQ=/usr/bin/jq
[ -x "$JQ" ] || { echo "atreya: /usr/bin/jq not found (needs macOS 15+)" >&2; exit 1; }

die()  { echo "atreya: $*" >&2; exit 1; }
warn() { echo "atreya: warning: $*" >&2; }
today() { date +%Y-%m-%d; }

# ---------------------------------------------------------------- workspace
# atreya_root [PATH] -> absolute workspace root (~ expanded), or die.
atreya_root() {
  local r="${1:-${ATREYA_ROOT:-${CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT:-$HOME/Mohini/atreya-ai}}}"
  case "$r" in "~"|"~/"*) r="$HOME${r#\~}" ;; esac
  [ -d "$r" ] || die "workspace root not found: $r (set workspace_root)"
  (cd "$r" && pwd -P)
}

# parse_root_arg "$@" -> sets ROOT and ARGS (remaining arguments).
parse_root_arg() {
  local r=""; ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) r="$2"; shift 2 ;;
      --root=*) r="${1#--root=}"; shift ;;
      *) ARGS[${#ARGS[@]}]="$1"; shift ;;
    esac
  done
  ROOT=$(atreya_root "$r") || exit 1
  DOCS="$ROOT/atreya-docs"
}

# repo_dir NAME_OR_PATH -> absolute path of a repo under <root>/repos, or die.
repo_dir() {
  local n="$1" d
  case "$n" in /*) d="$n" ;; *) d="$ROOT/repos/$n" ;; esac
  [ -d "$d" ] || die "repo not found: $d"
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $d"
  (cd "$d" && pwd -P)
}

# repo_stamp REPO_DIR -> full HEAD commit hash (the doc "built from" stamp).
repo_stamp() { git -C "$1" rev-parse HEAD 2>/dev/null || die "cannot read HEAD of $1"; }

# ---------------------------------------------------------------- secret files
# Same list as hooks/guard.sh is_secret_name (tests/scripts-tests.sh checks it).
ATREYA_SECRET_NAMES=".env .env.* *.jks *.keystore firebase-*.json google-services.json GoogleService-Info.plist gchat_logger.dart flavor_config.dart SamvitPaymentBridgeController.php (except .env.example)"

# awk program: reads paths on stdin, prints only NON-secret ones.
ATREYA_SECRET_FILTER='
{ n = $0; sub(/.*\//, "", n); n = tolower(n)
  if (n == ".env.example") { print; next }
  if (n == ".env" || n ~ /^\.env\./ || n ~ /\.jks$/ || n ~ /\.keystore$/ ||
      n ~ /^firebase-.*\.json$/ || n == "google-services.json" ||
      n == "googleservice-info.plist" || n == "gchat_logger.dart" || n == "flavor_config.dart" ||
      n == "samvitpaymentbridgecontroller.php") next
  print }'

is_secret_name() {
  [ -n "$(printf '%s\n' "$1" | awk "$ATREYA_SECRET_FILTER")" ] && return 1
  return 0
}

# tracked_files REPO_DIR [PATHSPEC...] -> tracked, NON-secret files, one per line,
# sorted (git order), relative to the repo. WHY tracked only: every teammate
# gets the same input, and untracked local files never leak into docs.
# Scripts must read repo files ONLY through this list (scripts/extract-baseurl.sh
# is the single, tested exception).
tracked_files() {
  local repo="$1"; shift
  git -C "$repo" ls-files -- "$@" | awk "$ATREYA_SECRET_FILTER"
}

# json_str VALUE -> JSON string literal
json_str() { printf '%s' "$1" | "$JQ" -Rs .; }
