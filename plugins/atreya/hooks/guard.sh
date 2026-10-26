#!/bin/bash
# atreya guard: PreToolUse hook for EVERY tool call.
#
# Runs on stock macOS: bash 3.2, /usr/bin/jq (ships with macOS 15+), awk, find, git.
# FAIL-CLOSED: any path out of this script that is not an explicit decision
# (crash, unset jq, unparseable JSON, unexpected exit) blocks the tool call.
#
# Decisions:
#   pass  -> exit 0, no output  (normal Claude Code permissions still apply;
#                                we never emit "allow", so we never auto-approve)
#   block -> exit 2, reason on stderr (Claude sees the reason)
#   ask   -> exit 0, JSON permissionDecision "ask" (user must confirm)
#
# Rules (letters match references/safety-rules.md):
#   a secret files   b repo writes   c git allow-list   d artisan allow-list
#   e package installs   f production hosts   g Zoho Sprints   s self-protection
# Rules only ever ADD restrictions; none of them grants permission another one
# denies, so they cannot contradict each other. Order does not matter.

# ---------------------------------------------------------------- fail-closed core
DECIDED=0
on_exit() {
  local rc=$?
  if [ "$DECIDED" != 1 ]; then
    echo "atreya-guard: internal error (rc=$rc); blocking because the guard is fail-closed." >&2
    exit 2
  fi
}
trap on_exit EXIT

pass()  { DECIDED=1; exit 0; }
block() { DECIDED=1; echo "atreya-guard BLOCKED [$1]: $2" >&2; exit 2; }
ask()   {
  DECIDED=1
  # Reasons are fixed strings from this file; still escape quotes/backslashes.
  local r; r=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$r"
  exit 0
}

# ---------------------------------------------------------------- input
JQ=/usr/bin/jq
[ -x "$JQ" ] || block parse "/usr/bin/jq not found (needs macOS 15+)."
INPUT=$(cat) || block parse "could not read hook input."
[ -n "$INPUT" ] || block parse "empty hook input."
printf '%s' "$INPUT" | "$JQ" -e 'type=="object" and (.tool_name|type=="string")' >/dev/null 2>&1 \
  || block parse "hook input is not valid JSON with a tool_name."

jget() { printf '%s' "$INPUT" | "$JQ" -r "$1 // empty | if type==\"string\" then . else tojson end" 2>/dev/null; }

TOOL=$(jget .tool_name)
CWD=$(jget .cwd); [ -n "$CWD" ] || CWD=$PWD

# ---------------------------------------------------------------- small helpers
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# abspath PATH BASE [DEPTH] -> physical absolute path (symlinks resolved
# component by component, so "../" and links behave like the kernel's).
# WHY: a write to /tmp/link/../x must not escape into repos/ via a symlink.
abspath() {
  local p="$1" base="$2" depth="${3:-0}" cur="/" part nxt t
  [ "$depth" -lt 8 ] || { echo "/__symlink_loop__"; return; }
  case "$p" in "~") p="$HOME";; "~/"*) p="$HOME/${p#\~/}";; esac
  case "$p" in /*) ;; *) p="$base/$p";; esac
  local oldifs=$IFS; IFS='/'; set -f
  for part in $p; do
    case "$part" in
      ""|.) ;;
      ..) cur="${cur%/*}"; [ -n "$cur" ] || cur="/" ;;
      *)  if [ "$cur" = "/" ]; then nxt="/$part"; else nxt="$cur/$part"; fi
          if [ -L "$nxt" ]; then
            t=$(readlink "$nxt")
            IFS=$oldifs; set +f
            cur=$(abspath "$t" "$cur" $((depth+1)))
            IFS='/'; set -f
          else cur="$nxt"; fi ;;
    esac
  done
  IFS=$oldifs; set +f
  echo "$cur"
}

# under PATH DIR -> true if PATH is DIR or inside it. Case-insensitive
# because the default macOS filesystem is (repos/ == Repos/).
under() {
  local p d; p=$(lower "$1"); d=$(lower "${2%/}")
  [ "$p" = "$d" ] && return 0
  case "$p" in "$d"/*) return 0;; esac
  return 1
}

# ---------------------------------------------------------------- workspace
PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)}
[ -n "$PLUGIN_ROOT" ] || block config "cannot locate plugin root."
PLUGIN_ROOT=$(abspath "$PLUGIN_ROOT" /)
ROOT=$(abspath "${CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT:-$HOME/Mohini/atreya-ai}" "$HOME")
REPOS="$ROOT/repos"; DOCS="$ROOT/atreya-docs"; QA="$ROOT/atreya-qa"
CWD=$(abspath "$CWD" /)

# ---------------------------------------------------------------- rule a: secrets
# WHY: these files hold credentials/keys (and several are committed to git), so
# their contents must never enter Claude's context. .env.example is a template.
# flavor_config.dart holds Razorpay keys next to the app's baseUrl; only the
# plugin's tested extractor (scripts/extract-baseurl.sh) reads it, and it prints
# nothing but redacted baseUrl values.
# Keep this list identical to ATREYA_SECRET_NAMES in scripts/lib/common.sh
# (tests/scripts-tests.sh checks that).
is_secret_name() {
  local n; n=$(lower "${1##*/}")
  case "$n" in
    .env.example) return 1 ;;
    .env|.env.*|*.jks|*.keystore|firebase-*.json|google-services.json|googleservice-info.plist|gchat_logger.dart|flavor_config.dart) return 0 ;;
    # Found by the 2026-10-26 secret scan: live Razorpay credentials in code.
    samvitpaymentbridgecontroller.php) return 0 ;;
  esac
  return 1
}

# text_names_secret TEXT -> true if a glob/pattern string names a secret file.
# Used for Glob patterns and Grep glob/pattern. ".env.example" is removed first.
text_names_secret() {
  local t; t=$(lower "$1" | sed 's/\.env\.example//g')
  case "$t" in
    *.env*|*.jks*|*.keystore*|*firebase-*|*google-services*|*googleservice-info*|*gchat_logger*|*flavor_config*|*samvitpaymentbridgecontroller*) return 0 ;;
  esac
  return 1
}

# too_broad DIR -> true for /, $HOME, or any ancestor of the workspace root.
# WHY: scanning them for secrets would be slow enough to hit the hook timeout,
# and a timed-out hook does not block (that would be fail-open).
too_broad() {
  local d; d=$(lower "${1%/}")
  [ -z "$d" ] && return 0
  [ "$d" = "$(lower "$HOME")" ] && return 0
  under "$ROOT" "$1" && [ "$(lower "$ROOT")" != "$d" ] && return 0
  return 1
}

# secret_under DIR -> prints the first secret file below DIR (names only;
# contents are never opened). Empty output = DIR is safe to content-search.
secret_under() {
  find "$1" -name .git -prune -o \( -type f -o -type l \) \( \
      -iname .env -o -iname '.env.*' -o -iname '*.jks' -o -iname '*.keystore' \
      -o -iname 'firebase-*.json' -o -iname google-services.json \
      -o -iname GoogleService-Info.plist -o -iname gchat_logger.dart \
      -o -iname flavor_config.dart -o -iname SamvitPaymentBridgeController.php \) \
      ! -iname .env.example -print 2>/dev/null | head -n 1
}

# ---------------------------------------------------------------- rule f: hosts
# WHY: QA runs against staging only; touching production could change real
# patient data. Exact host + its subdomains; siblings like staging-* are fine.
HOSTS_FILE="$PLUGIN_ROOT/config/prod-hosts.txt"
HOSTS=""; HOSTS_OK=0
if [ -r "$HOSTS_FILE" ]; then
  HOSTS=$(sed 's/#.*//' "$HOSTS_FILE" | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' | grep -v '^$')
  [ -n "$HOSTS" ] && HOSTS_OK=1
fi
HOST_HIT=""
host_hit() {
  [ "$HOSTS_OK" = 1 ] || { HOST_HIT="(prod-hosts.txt missing or empty)"; return 0; }  # fail-closed
  local text h esc; text=$(lower "$1")
  for h in $HOSTS; do
    esc=$(printf '%s' "$h" | sed 's/[.]/\\./g')
    if printf '%s' "$text" | grep -Eq "(^|[^a-z0-9.-])([a-z0-9-]+\.)*${esc}([^a-z0-9.-]|$)"; then
      HOST_HIT=$h; return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- rule b: gate
# WHY: repos are product code. A write is only OK when a human has approved a
# specific ticket AND created a feature branch (never master/main/production).
GATE_WHY=""
gate_ok() {  # gate_ok REPO_NAME
  local repo="$1" at="$DOCS/dev/.active-ticket" t b
  [ -n "$repo" ] || { GATE_WHY="target is repos/ itself, not inside a repo"; return 1; }
  [ -f "$at" ] || { GATE_WHY="no $at"; return 1; }
  t=$(head -n 1 "$at" | tr -d ' \t\r\n')
  case "$t" in ""|.|..|*[!A-Za-z0-9._-]*) GATE_WHY=".active-ticket must name one ticket ([A-Za-z0-9._-])"; return 1 ;; esac
  [ -f "$DOCS/dev/$t/APPROVED" ] || { GATE_WHY="ticket $t has no atreya-docs/dev/$t/APPROVED"; return 1; }
  b=$(git -C "$REPOS/$repo" symbolic-ref --short -q HEAD 2>/dev/null)
  [ -n "$b" ] || { GATE_WHY="cannot read current branch of $repo (detached HEAD or not a git repo)"; return 1; }
  case "$(lower "$b")" in master|main|production) GATE_WHY="$repo is on protected branch $b"; return 1 ;; esac
  return 0
}
repo_of() {  # repo_of ABS_PATH -> first path component below repos/
  local rel="${1#"$REPOS"}"; rel="${rel#/}"; echo "${rel%%/*}"
}

# ---------------------------------------------------------------- rule s: self-protection
# WHY: Claude must not weaken its own guard (plugin files, hook settings) or
# forge/remove a human approval (any file named APPROVED).
PROT_WHY=""
protected_path() {  # protected_path ABS_PATH
  local p="$1" lp b; lp=$(lower "$p"); b=$(lower "${p##*/}")
  [ "$b" = approved ] && { PROT_WHY="APPROVED files are created by humans only"; return 0; }
  under "$p" "$PLUGIN_ROOT" && { PROT_WHY="plugin files"; return 0; }
  under "$p" "$HOME/.claude/plugins" && { PROT_WHY="installed plugins"; return 0; }
  case "$lp" in
    "$(lower "$HOME")/.claude.json") PROT_WHY="Claude Code config"; return 0 ;;
    */.claude/settings.json|*/.claude/settings.local.json) PROT_WHY="Claude Code settings (could disable this guard)"; return 0 ;;
  esac
  return 1
}
# protected_inside ABS_PATH -> true if a protected thing lives below PATH
# (rm -rf / mv of a parent folder would remove it).
protected_inside() {
  local p="$1"
  [ -d "$p" ] || return 1
  under "$PLUGIN_ROOT" "$p" && { PROT_WHY="contains the plugin"; return 0; }
  under "$HOME/.claude" "$p" && { PROT_WHY="contains ~/.claude"; return 0; }
  under "$REPOS" "$p" && { PROT_WHY="contains repos/"; return 0; }
  if [ -n "$(find "$p" -iname APPROVED -print 2>/dev/null | head -n 1)" ]; then
    PROT_WHY="contains an APPROVED file"; return 0
  fi
  return 1
}

# check_write ABS_PATH CONTEXT_DIR -> blocks unless writing PATH is allowed.
# Shared by Edit/Write tools and Bash write detection so both behave the same.
check_write() {
  local p="$1" ctx="$2" repo
  protected_path "$p" && block self-protect "$p: $PROT_WHY."
  if under "$p" "$REPOS"; then
    repo=$(repo_of "$p")
    gate_ok "$repo" || block repo-write "$p is under repos/ (read-only): $GATE_WHY."
    return 0
  fi
  # cwd inside repos/: only atreya-docs/, atreya-qa/ and /tmp may be written
  # (e.g. php artisan route:list --json > <root>/atreya-docs/...).
  if [ -n "$ctx" ] && under "$ctx" "$REPOS"; then
    under "$p" "$DOCS" || under "$p" "$QA" || under "$p" /private/tmp || under "$p" /tmp \
      || block repo-write "cwd is inside repos/; writes may only target atreya-docs/, atreya-qa/ or /tmp (got $p)."
  fi
  return 0
}

# ---------------------------------------------------------------- Grep filter helpers
# secret_list DIR -> all secret files below DIR (names only).
secret_list() {
  find "$1" -name .git -prune -o \( -type f -o -type l \) \( \
      -iname .env -o -iname '.env.*' -o -iname '*.jks' -o -iname '*.keystore' \
      -o -iname 'firebase-*.json' -o -iname google-services.json \
      -o -iname GoogleService-Info.plist -o -iname gchat_logger.dart \
      -o -iname flavor_config.dart -o -iname SamvitPaymentBridgeController.php \) \
      ! -iname .env.example -print 2>/dev/null
}
# type_globs TYPE -> ripgrep type as globs; unknown type prints "*" (fail-closed:
# treat it as matching everything, including secrets).
type_globs() {
  case "$(lower "$1")" in
    php) echo "*.php *.php3 *.php4 *.php5 *.phtml" ;;
    js) echo "*.js *.jsx *.mjs *.cjs *.vue" ;;
    ts) echo "*.ts *.tsx *.cts *.mts" ;;
    dart) echo "*.dart" ;;  json) echo "*.json *.jsonl *.json5 *.sarif" ;;
    css) echo "*.css *.scss" ;; html) echo "*.html *.htm *.ejs" ;;
    md|markdown) echo "*.md *.markdown *.mdx" ;; py) echo "*.py *.pyi" ;;
    sh) echo "*.sh *.bash *.zsh" ;; yaml) echo "*.yaml *.yml" ;; sql) echo "*.sql" ;;
    swift) echo "*.swift" ;; kotlin) echo "*.kt *.kts" ;; java) echo "*.java" ;;
    *) echo "*" ;;
  esac
}
# glob_list GLOB -> one pattern per word; expands ONE {a,b} group. Negation or
# nested braces -> "*" (fail-closed).
glob_list() {
  local g="$1" pre post mid
  case "$g" in '!'*|*'{'*'{'*) echo "*"; return ;; esac
  case "$g" in
    *'{'*'}'*) pre=${g%%\{*}; mid=${g#*\{}; post=${mid#*\}}; mid=${mid%%\}*}
               printf '%s\n' "$mid" | tr ',' '\n' | while read -r m; do echo "$pre$m$post"; done ;;
    *) echo "$g" ;;
  esac
}
# glob_hits FILE ROOTDIR PATTERN... -> true if FILE matches any pattern the
# way ripgrep would (basename unless the pattern has a '/').
glob_hits() {
  local f="$1" root="$2" pat rel base; shift 2
  rel=$(lower "${f#"$root"/}"); base=$(lower "${f##*/}")
  for pat in "$@"; do
    pat=$(lower "$pat"); pat=${pat#\*\*/}
    case "$pat" in
      */*) case "$rel" in $pat) return 0;; esac ;;
      *)   case "$base" in $pat) return 0;; esac ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------- non-Bash tools
handle_file_tool() {  # Read / Edit / Write / MultiEdit / NotebookEdit
  local fp p; fp=$(jget .tool_input.file_path); [ -n "$fp" ] || fp=$(jget .tool_input.notebook_path)
  [ -n "$fp" ] || block parse "$TOOL call without a file path."
  p=$(abspath "$fp" "$CWD")
  is_secret_name "$p" && block secret "$p is a secret file (.env/.jks/keystore/firebase/google-services/gchat_logger/flavor_config)."
  case "$TOOL" in
    Read) pass ;;
    *) check_write "$p" ""; pass ;;   # rule b + rule s
  esac
}

handle_glob() {
  local pat path; pat=$(jget .tool_input.pattern); path=$(jget .tool_input.path)
  text_names_secret "$pat" && block secret "Glob pattern targets secret files: $pat"
  [ -n "$path" ] && is_secret_name "$path" && block secret "Glob path is a secret file: $path"
  pass   # Glob only returns names, never contents
}

handle_grep() {
  local path p glob typ mode s pats=""
  path=$(jget .tool_input.path); [ -n "$path" ] || path=$CWD
  p=$(abspath "$path" "$CWD")
  glob=$(jget .tool_input.glob); typ=$(jget .tool_input.type); mode=$(jget .tool_input.output_mode)
  is_secret_name "$p" && block secret "Grep path is a secret file: $p"
  [ -n "$glob" ] && text_names_secret "$glob" && block secret "Grep glob targets secret files: $glob"
  # Names-only modes never print file contents -> always fine (default mode).
  case "$mode" in ""|files_with_matches|count) pass ;; esac
  [ -d "$p" ] || pass                     # single non-secret file
  too_broad "$p" && block secret "content Grep over $p is too broad to check for secret files; narrow the path."
  local secrets; secrets=$(secret_list "$p")
  [ -n "$secrets" ] || pass
  # Content mode over a folder that holds secrets: allowed only if glob/type
  # filters exclude every one of them.
  local IFS_old=$IFS; IFS=$'\n'
  for s in $secrets; do
    IFS=$IFS_old
    local hit=1
    if [ -n "$glob" ]; then set -f; glob_hits "$s" "$p" $(glob_list "$glob") || hit=0; set +f; fi
    if [ -n "$typ" ]; then set -f; glob_hits "$s" "$p" $(type_globs "$typ") || hit=0; set +f; fi
    [ "$hit" = 1 ] && block secret "content Grep in $p would read secret file $s. Use output_mode files_with_matches, a narrower path, or a glob/type that excludes it."
    IFS=$'\n'
  done
  IFS=$IFS_old
  pass
}

handle_mcp_and_web() {
  local lt; lt=$(lower "$TOOL")
  # rule g: Zoho Sprints. Match "ZohoSprints_" (not the connector prefix) so
  # every teammate's connector name is covered. WHY: tickets are shared team
  # state; reads are safe, every change needs a human yes.
  case "$TOOL" in
    *ZohoSprints_*)
      case "${TOOL##*ZohoSprints_}" in
        Get*) pass ;;
        *) ask "Zoho Sprints change (${TOOL##*ZohoSprints_}): confirm before it runs." ;;
      esac ;;
  esac
  # Other Zoho apps are not part of this workflow: reads pass, writes blocked.
  case "$lt" in
    *zoho*)
      local act="${TOOL##*__}"; case "$act" in *_*) act="${act#*_}";; esac
      case "$(lower "$act")" in get*|list*|search*) pass ;; esac
      block zoho "$TOOL is a non-Sprints Zoho write; only Zoho Sprints is used here." ;;
  esac
  # rule f: browser automation and fetch tools must not reach production.
  case "$lt" in
    *playwright*|*browser*|*chrome*|*puppeteer*|*selenium*|webfetch|*__fetch*|*web_fetch*)
      host_hit "$(jget .tool_input)" && block prod-host "$TOOL targets production host $HOST_HIT; use staging." ;;
  esac
  pass
}

# ================================================================ Bash analysis
# The command is split by a small awk tokenizer that understands quotes,
# escapes, ; && || | & ( ) $( ) ` `, redirections and heredocs. Each simple
# command ("segment") is then checked. Anything it cannot understand blocks.
AWK_TOK='
function flush() { if (inw) { gsub(/\n/, " ", w); print w; w = ""; inw = 0 } }
function sep() { flush(); print "@@SEP@@" }
# grab a $( ... ) body starting at i (just after "$("); returns end index
function grab_sub(i,   d, c, body, j) {
  d = 1; body = ""
  while (i <= n) { c = substr(s, i, 1)
    # quoted text inside $( ... ) may contain parentheses: copy it whole
    if (c == "\047") { j = index(substr(s, i + 1), "\047"); if (j == 0) break; body = body substr(s, i, j + 1); i += j + 1; continue }
    if (c == "\"") { j = i + 1
      while (j <= n && substr(s, j, 1) != "\"") { if (substr(s, j, 1) == "\\") j++; j++ }
      if (j > n) break; body = body substr(s, i, j - i + 1); i = j + 1; continue }
    if (c == "\\") { body = body substr(s, i, 2); i += 2; continue }
    if (c == "(") d++
    if (c == ")") { d--; if (d == 0) break }
    body = body c; i++ }
  if (i > n) { print "@@ERR@@"; exit }
  gsub(/\n/, ";", body); print "@@SUB@@" body; return i
}
{ s = s (NR > 1 ? "\n" : "") $0 }
END {
  n = length(s); i = 1; w = ""; inw = 0; hd = ""
  while (i <= n) {
    c = substr(s, i, 1); nx = substr(s, i + 1, 1)
    if (c == "\\") { if (nx == "\n") { i += 2; continue } w = w nx; inw = 1; i += 2; continue }
    if (c == "\047") { rest = substr(s, i + 1); j = index(rest, "\047")
      if (j == 0) { print "@@ERR@@"; exit }
      w = w substr(rest, 1, j - 1); inw = 1; i += j + 1; continue }
    if (c == "\"") { i++
      while (i <= n) { c = substr(s, i, 1)
        if (c == "\\") { w = w substr(s, i + 1, 1); i += 2; continue }
        if (c == "\"") break
        if (c == "$" && substr(s, i + 1, 1) == "(") { i = grab_sub(i + 2) + 1; continue }
        if (c == "`") { rest = substr(s, i + 1); j = index(rest, "`")
          if (j == 0) { print "@@ERR@@"; exit }
          b = substr(rest, 1, j - 1); gsub(/\n/, ";", b); print "@@SUB@@" b; i += j + 1; continue }
        w = w c; i++ }
      if (i > n) { print "@@ERR@@"; exit }
      inw = 1; i++; continue }
    if (c == " " || c == "\t") { flush(); i++; continue }
    if (c == "\n") { sep(); i++
      if (hd != "") {
        while (i <= n) { e = index(substr(s, i), "\n")
          if (e == 0) { line = substr(s, i); i = n + 1 } else { line = substr(s, i, e - 1); i += e }
          t = line; if (hdtab) sub(/^\t+/, "", t)
          if (t == hd) break }
        hd = "" }
      continue }
    if (c == ";") { sep(); i++; continue }
    if (c == "&") { if (nx == "&") { sep(); i += 2; continue }
      if (nx == ">") { flush(); i += 2; if (substr(s, i, 1) == ">") i++; print "@@RW@@"; continue }
      sep(); i++; continue }
    if (c == "|") { sep(); i += (nx == "|" || nx == "&") ? 2 : 1; continue }
    if (c == "(" || c == ")" || c == "`") { sep(); i++; continue }
    if (c == "$" && nx == "(") { sep(); i += 2; continue }
    if (c == ">") {
      if (inw && w ~ /^[0-9]+$/) { w = ""; inw = 0 } else flush()
      i++; c = substr(s, i, 1)
      if (c == ">" || c == "|") { i++; c = substr(s, i, 1) }
      if (c == "&") { i++; if (substr(s, i, 1) ~ /[0-9-]/) { while (substr(s, i, 1) ~ /[0-9-]/) i++; continue } }
      print "@@RW@@"; continue }
    if (c == "<") { flush(); i++; c = substr(s, i, 1)
      if (c == "(") { sep(); i++; continue }
      if (c == "&") { i++; while (substr(s, i, 1) ~ /[0-9-]/) i++; continue }
      if (c == "<") { i++
        if (substr(s, i, 1) == "<") { i++; print "@@HS@@"; continue }
        hdtab = 0; if (substr(s, i, 1) == "-") { hdtab = 1; i++ }
        while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
        d = ""
        while (i <= n) { c = substr(s, i, 1)
          if (c ~ /[ \t\n;|&<>()]/) break
          if (c != "\047" && c != "\"" && c != "\\") d = d c
          i++ }
        if (d == "") { print "@@ERR@@"; exit }
        hd = d; continue }
      print "@@RD@@"; continue }
    if (c == "#" && !inw) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
    w = w c; inw = 1; i++
  }
  flush()
  if (hd != "") { print "@@ERR@@" }
}'

SUBQ=(); SUBQD=(); CMDWORDS=""; SEGDIR=""; XARGS=0
SW=(); SR=()

# analyze_bash COMMAND DIR
analyze_bash() {
  local toks t expect="" k=0
  toks=$(printf '%s' "$1" | awk "$AWK_TOK") || block parse "could not tokenize the command."
  case "$toks" in *@@ERR@@*) block parse "unbalanced quotes/heredoc/substitution; cannot check this command." ;; esac
  local -a TK=()
  while IFS= read -r t; do TK[${#TK[@]}]="$t"; done <<EOF
$toks
EOF
  SEGDIR="$2"; SW=(); SR=()
  while [ $k -lt ${#TK[@]} ]; do
    t=${TK[$k]}; k=$((k+1))
    case "$t" in
      @@SEP@@) seg_done; continue ;;
      @@RW@@) expect=w; continue ;;
      @@RD@@) expect=r; continue ;;
      @@HS@@) expect=s; continue ;;
      @@SUB@@*) SUBQ[${#SUBQ[@]}]="${t#@@SUB@@}"; SUBQD[${#SUBQD[@]}]="$SEGDIR"; continue ;;
    esac
    case "$expect" in
      w) SR[${#SR[@]}]="$t"; expect=""; continue ;;
      r) is_secret_name "$t" && block secret "input redirect from secret file $t."; expect=""; continue ;;
      s) expect=""; continue ;;
    esac
    SW[${#SW[@]}]="$t"
  done
  [ "$expect" = w ] && block parse "redirect without a target."
  seg_done
}

seg_done() {
  if [ ${#SW[@]} -gt 0 ] || [ ${#SR[@]} -gt 0 ]; then analyze_segment; fi
  SW=(); SR=()
}

analyze_segment() {
  local i=0 n=${#SW[@]} w cmd a e t p
  XARGS=0
  # Skip assignments and wrappers to find the real command word.
  while [ $i -lt $n ]; do
    w=${SW[$i]}
    case "$w" in
      [A-Za-z_]*=*) case "${w%%=*}" in *[!A-Za-z0-9_]*) break ;; esac; i=$((i+1)); continue ;;
      sudo|command|builtin|exec|nohup|time|then|do|else|elif|if|while|until|'!'|'{'|'}'|done|fi|esac|noglob)
        i=$((i+1)); continue ;;
      env|nice|timeout|caffeinate|stdbuf)
        i=$((i+1))
        while [ $i -lt $n ]; do case "${SW[$i]}" in -*|[0-9]*|[A-Za-z_]*=*) i=$((i+1)) ;; *) break ;; esac; done
        continue ;;
      xargs)
        XARGS=1; i=$((i+1))
        while [ $i -lt $n ]; do
          case "${SW[$i]}" in -I|-n|-P|-L|-d|-s|-E|-a|-J|-R|-S) i=$((i+2)) ;; -*) i=$((i+1)) ;; *) break ;; esac
        done
        continue ;;
    esac
    break
  done
  local -a A=()
  if [ $i -lt $n ]; then cmd=$(lower "${SW[$i]##*/}"); A=("${SW[@]:$((i+1))}"); else cmd=""; fi
  CMDWORDS="$CMDWORDS $cmd"

  # rule a: shell globs that would expand to a secret file (cat config/*).
  for a in "${A[@]}"; do
    case "$a" in *[*?[]*)
      while IFS= read -r e; do
        [ -n "$e" ] && is_secret_name "$e" && block secret "'$a' expands to secret file $e."
      done <<EOF
$(cd "$SEGDIR" 2>/dev/null && compgen -G "$a" 2>/dev/null)
EOF
    ;; esac
  done

  # rule b/s: output redirections.
  for t in "${SR[@]}"; do
    case "$t" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) continue ;; esac
    case "$t" in *'$'*|*'`'*|*'*'*|*'?'*) block repo-write "redirect target '$t' is not a fixed path; cannot check it." ;; esac
    p=$(abspath "$t" "$SEGDIR")
    is_secret_name "$p" && block secret "redirect into secret file $p."
    check_write "$p" "$SEGDIR"
  done

  [ -n "$cmd" ] || return 0
  case "$cmd" in
    cd|pushd) do_cd ;;
    git) git_check ;;
    php) if has_artisan; then artisan_check; else interp_check; fi ;;
    artisan) artisan_check ;;
    composer|npm|pnpm|yarn|pip|pip3|pod|flutter|dart|bundle) pkg_check "$cmd" ;;
    python|python3) if [ "${A[0]}" = -m ] && [ "${A[1]}" = pip ]; then A=("${A[@]:2}"); pkg_check pip; else interp_check; fi ;;
    grep|egrep|fgrep|rg|ag|ack) search_check "$cmd" ;;
    find) find_check ;;
    bash|sh|zsh|dash|ksh) shell_c_check ;;
    eval) block parse "eval cannot be checked; run the command directly." ;;
    node|ruby|perl|deno|bun) interp_check ;;
    *) write_check "$cmd" ;;
  esac
  # xargs feeds file names we cannot see.
  if [ "$XARGS" = 1 ]; then xargs_check "$cmd"; fi
  return 0
}

do_cd() {
  local d=""
  for a in "${A[@]}"; do case "$a" in -L|-P|-e|-@) ;; *) d=$a; break ;; esac; done
  [ -n "$d" ] || d=$HOME
  case "$d" in -|*'$'*|*'`'*) block parse "cd to a dynamic path ($d) cannot be checked." ;; esac
  SEGDIR=$(abspath "$d" "$SEGDIR")
}

# ---------------------------------------------------------------- rule c: git
# WHY: git writes (commit, checkout, reset, push, stash, ...) change shared
# history or the working tree; a human does them. Only listed reads pass.
# Because secrets ARE committed in these repos, read commands that print file
# contents must also prove they do not include a secret file.
git_check() {
  local gd="$SEGDIR" j=0 a sub
  while [ $j -lt ${#A[@]} ]; do
    a=${A[$j]}
    case "$a" in
      -C) [ $((j+1)) -lt ${#A[@]} ] || block git "git -C without a path."
          gd=$(abspath "${A[$((j+1))]}" "$gd"); j=$((j+2)) ;;
      --no-pager|--no-optional-locks|-P|--paginate|--literal-pathspecs|--no-replace-objects) j=$((j+1)) ;;
      --git-dir=*|--work-tree=*) j=$((j+1)) ;;
      --version|--help) return 0 ;;
      -c|-c*|--config-env*|--exec-path*) block git "git $a can run arbitrary commands via config." ;;
      -*) block git "unknown git option $a." ;;
      *) break ;;
    esac
  done
  sub=${A[$j]}
  [ -n "$sub" ] || return 0
  local -a R=("${A[@]:$((j+1))}")
  for a in "${R[@]}"; do
    case "$a" in
      --output|--output=*) block git "--output writes a file." ;;
      --ext-diff|--no-index|--textconv) block git "$a is not allowed (runs tools / reads outside git)." ;;
    esac
  done
  case "$sub" in
    status|rev-parse|ls-files) return 0 ;;
    remote) for a in "${R[@]}"; do case "$a" in -v|--verbose) ;; *) block git "only 'git remote' and 'git remote -v' are allowed." ;; esac; done; return 0 ;;
    branch) git_branch_check; return 0 ;;
    log|show|diff|grep|blame) git_content_check "$sub" "$gd"; return 0 ;;
  esac
  block git "git $sub is not on the read-only allow-list (status diff log show blame branch rev-parse ls-files grep 'remote -v'). A human runs git writes."
}

git_branch_check() {
  local listing=0 a
  for a in "${R[@]}"; do
    case "$a" in --list|-l|--contains*|--no-contains*|--merged*|--no-merged*|--points-at*|--sort=*|--format=*) listing=1 ;; esac
  done
  for a in "${R[@]}"; do
    case "$a" in
      -a|-r|-v|-vv|--all|--remotes|--verbose|--show-current|--no-color|--color|--color=*|--list|-l) ;;
      --contains*|--no-contains*|--merged*|--no-merged*|--points-at*|--sort=*|--format=*|--column*|--no-column|-i|--ignore-case|--abbrev*|--no-abbrev) ;;
      -*) case "$a" in -[arvl]*) case "${a#-}" in *[!arvl]*) block git "git branch $a changes branches." ;; esac ;;
                       *) block git "git branch $a changes branches." ;; esac ;;
      *) [ $listing = 1 ] || block git "git branch <name> creates a branch; use 'git branch --list <pattern>'." ;;
    esac
  done
}

git_content_check() {
  local sub="$1" gd="$2" a summary=0 patch=0 names=0 seen_dd=0 revpath=0 other=0 f
  local -a PS=()
  for a in "${R[@]}"; do
    if [ $seen_dd = 1 ]; then PS[${#PS[@]}]="$a"; continue; fi
    case "$a" in
      --) seen_dd=1 ;;
      --stat*|--numstat|--shortstat|--name-only|--name-status|--summary|--dirstat*|-s|--no-patch|--raw|--quiet) summary=1; names=1 ;;
      -p|-u|--patch|-U*|--unified*|--patch-with-stat|--patch-with-raw|-L*|--cc|--full-diff|-W|--function-context) patch=1 ;;
      -l|-L|-c|--count|--files-with-matches|--files-without-match|-q) names=1 ;;
      -O*|--open-files-in-pager*) [ "$sub" = grep ] && block git "git grep -O runs a pager command." ;;
      -*) if [ "$sub" = grep ]; then case "${a#-}" in *[lLcq]*) names=1 ;; esac; fi ;;
      *:*) is_secret_name "${a##*:}" && block secret "git $sub of secret file ${a##*:}."
           revpath=$((revpath+1)) ;;
      *) other=$((other+1)) ;;
    esac
  done
  local content=1
  case "$sub" in
    log)  [ $patch = 1 ] || content=0 ;;
    show|diff) [ $summary = 1 ] && [ $patch = 0 ] && content=0 ;;
    grep) [ $names = 1 ] && content=0 ;;
    blame) for a in "${R[@]}"; do is_secret_name "$a" && block secret "git blame of secret file $a."; done; return 0 ;;
  esac
  [ $content = 1 ] || return 0
  # git show REV:path (non-secret, checked above) prints just that file.
  [ "$sub" = show ] && [ $revpath -gt 0 ] && [ $other = 0 ] && [ ${#PS[@]} = 0 ] && return 0
  [ ${#PS[@]} -gt 0 ] || block secret "git $sub without '-- <path>' can print committed secret files (.env, firebase keys...). Add --stat/--name-only (or -l for grep), or limit it with '-- <path>'."
  # Pass all pathspecs together so git applies ':(exclude)' / ':!x' itself.
  local files; files=$(git -C "$gd" ls-files -- "${PS[@]}" </dev/null 2>/dev/null) \
    || block secret "cannot list files for git $sub pathspec (not a git repo?)."
  while IFS= read -r f; do
    [ -n "$f" ] && is_secret_name "$f" && block secret "git $sub pathspec includes secret file $f; narrow the path or exclude it with ':!$f'."
  done <<EOF
$files
EOF
  return 0
}

# ---------------------------------------------------------------- rule d: artisan
# WHY: artisan commands can migrate/seed/wipe databases or clear caches on a
# real environment. Only harmless introspection is allowed.
has_artisan() { local a; for a in "${A[@]}"; do [ "${a##*/}" = artisan ] && return 0; done; return 1; }
artisan_check() {
  local a seen=0 sub=""
  [ "$cmd" = artisan ] && seen=1
  for a in "${A[@]}"; do
    if [ $seen = 0 ]; then [ "${a##*/}" = artisan ] && seen=1; continue; fi
    case "$a" in -*) ;; *) sub=$a; break ;; esac
  done
  case "$sub" in ""|route:list|list|about) return 0 ;; esac
  block artisan "php artisan $sub is not allowed; only route:list, list and about."
}

# ---------------------------------------------------------------- rule e: installs
# WHY: installs rewrite lock files and vendor/node_modules in product repos.
# They stay blocked in repos/ even with an approved ticket; fine in atreya-qa/.
pkg_check() {
  local pm="$1" dir="$SEGDIR" j=0 a sub="" sub2="" install=0 global=0
  while [ $j -lt ${#A[@]} ]; do
    a=${A[$j]}
    case "$a" in
      --prefix|--dir|--cwd|--working-dir|--project-directory)
        dir=$(abspath "${A[$((j+1))]}" "$SEGDIR"); j=$((j+2)); continue ;;
      # -C (pnpm) and -d (composer) mean "directory" only for those tools.
      -C|-d) if { [ "$pm" = pnpm ] && [ "$a" = -C ]; } || { [ "$pm" = composer ] && [ "$a" = -d ]; }; then
               dir=$(abspath "${A[$((j+1))]}" "$SEGDIR"); j=$((j+2)); continue
             fi ;;
      --prefix=*|--cwd=*|--dir=*|--working-dir=*|--project-directory=*|--directory=*)
        dir=$(abspath "${a#*=}" "$SEGDIR") ;;
      -g|--global|--user) global=1 ;;
      -*) ;;
      *) if [ -z "$sub" ]; then sub=$a; elif [ -z "$sub2" ]; then sub2=$a; fi ;;
    esac
    j=$((j+1))
  done
  [ "$pm" = composer ] && [ "$sub" = global ] && global=1
  case "$pm:$sub" in
    npm:install|npm:i|npm:ci|npm:add|npm:update|npm:up|npm:upgrade|npm:uninstall|npm:remove|npm:rm|npm:r|npm:un|npm:unlink|npm:link|npm:ln|npm:dedupe|npm:prune|npm:rebuild|npm:install-test|npm:it|npm:install-ci-test|npm:cit) install=1 ;;
    npm:audit) [ "$sub2" = fix ] && install=1 ;;
    yarn:|yarn:install|yarn:add|yarn:remove|yarn:upgrade|yarn:up|yarn:upgrade-interactive|yarn:dedupe|yarn:link|yarn:unlink|yarn:import) install=1 ;;
    pnpm:install|pnpm:i|pnpm:add|pnpm:remove|pnpm:rm|pnpm:uninstall|pnpm:un|pnpm:update|pnpm:up|pnpm:upgrade|pnpm:prune|pnpm:link|pnpm:ln|pnpm:unlink|pnpm:import|pnpm:rebuild|pnpm:dedupe|pnpm:fetch) install=1 ;;
    composer:install|composer:i|composer:require|composer:r|composer:update|composer:u|composer:upgrade|composer:remove|composer:rm|composer:uninstall|composer:create-project|composer:reinstall|composer:bump|composer:dump-autoload|composer:dumpautoload) install=1 ;;
    pip:install|pip:uninstall|pip:download|pip3:install|pip3:uninstall|pip3:download) install=1 ;;
    pod:install|pod:update|pod:deintegrate) install=1 ;;
    flutter:pub|flutter:packages|dart:pub)
      case "$sub2" in get|upgrade|add|remove|downgrade|outdated) [ "$sub2" = outdated ] || install=1 ;; esac ;;
    bundle:|bundle:install|bundle:update|bundle:add|bundle:remove) install=1 ;;
  esac
  [ $install = 1 ] || return 0
  [ $global = 1 ] && return 0
  under "$dir" "$REPOS" && block install "$pm $sub ${sub2:+$sub2 }inside repos/ is blocked (even with an approved ticket); installs are allowed in atreya-qa/."
  return 0
}

# ---------------------------------------------------------------- rule a: recursive search
# WHY: on macOS `grep -r --exclude=.env` still reads .env, so excludes cannot
# be trusted. A recursive CONTENT search is allowed only if the folder holds
# no secret file. Names-only searches (-l/-c) never print contents: allowed.
search_check() {
  local tool="$1" j=0 a rec=0 names=0 haspat=0 dd=0 c2 k ch vals
  local -a OPS=()
  case "$tool" in grep|egrep|fgrep) vals="efABCmdD" ;; rg) rec=1; vals="efgtTmABCjMErd" ;; *) rec=1; vals="" ;; esac
  while [ $j -lt ${#A[@]} ]; do
    a=${A[$j]}; j=$((j+1))
    if [ $dd = 1 ]; then OPS[${#OPS[@]}]="$a"; continue; fi
    case "$a" in
      --) dd=1 ;;
      --pre|--pre=*|--pre-glob*) block secret "rg --pre runs a command on every file." ;;
      --recursive|--dereference-recursive|--directories=recurse) rec=1 ;;
      --files-with-matches|--files-without-match|--count|--count-matches|--quiet|--silent|--files) names=1 ;;
      --regexp=*|--file=*) haspat=1 ;;
      --regexp|--file) haspat=1; j=$((j+1)) ;;
      --directories) [ "${A[$j]}" = recurse ] && rec=1; j=$((j+1)) ;;
      --include|--exclude|--exclude-dir|--context|--max-count|--after-context|--before-context|--label|--devices|--binary-files|--glob|--iglob|--type|--type-not|--threads|--max-columns|--encoding|--type-add|--type-clear|--sort|--sortr|--max-depth|--colors|--path-separator|--replace|--max-filesize|--ignore-file|--engine)
        j=$((j+1)) ;;
      --*) ;;
      -?*) c2=${a#-}; k=0
           while [ $k -lt ${#c2} ]; do
             ch=${c2:$k:1}
             case "$vals" in *"$ch"*)
               case "$ch" in e|f) haspat=1 ;; esac
               if [ $((k+1)) -eq ${#c2} ]; then
                 [ "$ch" = d ] && [ "$tool" != rg ] && [ "${A[$j]}" = recurse ] && rec=1
                 j=$((j+1))
               fi
               break ;;
             esac
             case "$ch" in r|R) [ "$tool" = rg ] || rec=1 ;; l|L|c|q) names=1 ;; esac
             k=$((k+1))
           done ;;
      *) OPS[${#OPS[@]}]="$a" ;;
    esac
  done
  [ $names = 1 ] && return 0
  [ $haspat = 1 ] || OPS=("${OPS[@]:1}")
  [ $rec = 1 ] || return 0              # plain grep on named files: token check covers them
  [ "$XARGS" = 1 ] && return 0          # file list comes from stdin: xargs_check handles it
  [ ${#OPS[@]} -gt 0 ] || OPS=(.)
  for a in "${OPS[@]}"; do
    case "$a" in *'$'*|*'`'*) block secret "search path '$a' is not a fixed path; cannot check it for secrets." ;; esac
    p=$(abspath "$a" "$SEGDIR")
    [ -d "$p" ] || continue
    too_broad "$p" && block secret "recursive search over $p is too broad to check for secrets; narrow the folder."
    s=$(secret_under "$p")
    [ -n "$s" ] && block secret "recursive content search of $p would read secret file $s. Use 'grep -rl'/'rg -l' (names only), a narrower folder, or the Grep tool with a glob/type that excludes it."
  done
  return 0
}

is_write_verb() {
  case "$1" in tee|rm|rmdir|unlink|shred|trash|touch|mkdir|truncate|gzip|gunzip|bzip2|xz|unxz|chmod|chown|chgrp|mv|cp|install|ln|rsync|ditto|sed|perl|dd|curl|wget|unzip|tar|patch|zip|sort) return 0 ;; esac
  return 1
}

find_check() {
  local j=0 a ex=0 del=0 ecmd="" p s
  local -a SP=()
  while [ $j -lt ${#A[@]} ]; do
    case "${A[$j]}" in -*|'('|'!'|')') break ;; esac
    SP[${#SP[@]}]="${A[$j]}"; j=$((j+1))
  done
  [ ${#SP[@]} -gt 0 ] || SP=(.)
  while [ $j -lt ${#A[@]} ]; do
    a=${A[$j]}; j=$((j+1))
    case "$a" in
      -exec|-execdir|-ok|-okdir) ex=1; ecmd=$(lower "${A[$j]##*/}") ;;
      -delete) del=1 ;;
      -fprint|-fprint0|-fprintf|-fls) check_write "$(abspath "${A[$j]}" "$SEGDIR")" "$SEGDIR" ;;
    esac
  done
  for a in "${SP[@]}"; do
    case "$a" in *'$'*|*'`'*) [ $ex = 1 ] || [ $del = 1 ] && block parse "find start path '$a' is not fixed." ;; esac
    p=$(abspath "$a" "$SEGDIR")
    if [ $del = 1 ] || { [ $ex = 1 ] && is_write_verb "$ecmd"; }; then
      protected_path "$p" && block self-protect "find on $p: $PROT_WHY."
      protected_inside "$p" && block self-protect "find on $p: $PROT_WHY."
      check_write "$p" "$SEGDIR"
    fi
    if [ $ex = 1 ]; then
      case "$ecmd" in ls|stat|echo|basename|dirname|wc|file|du) continue ;; esac
      [ -d "$p" ] || continue
      too_broad "$p" && block secret "find -exec over $p is too broad to check for secrets."
      s=$(secret_under "$p")
      [ -n "$s" ] && block secret "find -exec $ecmd over $p would reach secret file $s; narrow the folder or use -name filters on a folder without secrets."
    fi
  done
  return 0
}

# bash -c / sh -c 'STRING': analyze STRING like a normal command.
shell_c_check() {
  local j=0 a
  while [ $j -lt ${#A[@]} ]; do
    a=${A[$j]}; j=$((j+1))
    case "$a" in
      -c|-[a-z]*c|-[a-z]*c[a-z]*) SUBQ[${#SUBQ[@]}]="${A[$j]}"; SUBQD[${#SUBQD[@]}]="$SEGDIR"; return 0 ;;
      -*) ;;
      *) return 0 ;;   # bash script.sh: runs a file (see safety-rules.md limits)
    esac
  done
}

# Inline interpreter code (python -c, node -e, php -r, perl -e ...) can write
# anything; inside repos/ we cannot see what, so it blocks. perl -i edits files.
interp_check() {
  local flags="" a j=0 inline=0 pi=0 ch
  local -a OPS=()
  case "$cmd" in php) flags="r" ;; python|python3) flags="c" ;; node|deno|bun) flags="ep" ;; ruby) flags="e" ;; perl) flags="eEipn" ;; esac
  while [ $j -lt ${#A[@]} ]; do
    a=${A[$j]}; j=$((j+1))
    case "$a" in
      --eval|--eval=*|--print|--print=*) inline=1 ;;
      --*) ;;
      -?*) for ch in e E r c p i n; do
             case "$flags" in *"$ch"*) case "${a#-}" in *"$ch"*) inline=1 ;; esac ;; esac
           done
           [ "$cmd" = perl ] && case "${a#-}" in *i*) pi=1 ;; esac
           [ "$cmd" = perl ] && case "${a#-}" in *e|*E) j=$((j+1)) ;; esac ;;
      *) OPS[${#OPS[@]}]="$a" ;;
    esac
  done
  if [ $inline = 1 ] && under "$SEGDIR" "$REPOS"; then
    block repo-write "inline $cmd code with cwd inside repos/ could write files the guard cannot see."
  fi
  if [ $pi = 1 ]; then
    for a in "${OPS[@]}"; do check_write "$(abspath "$a" "$SEGDIR")" "$SEGDIR"; done
  fi
  return 0
}

# ---------------------------------------------------------------- rule b: Bash writes
write_check() {
  local v="$1" j=0 a name val inplace=0 hasexpr=0 dest="" tdir="" mode="" archive="" oset=0 destructive=0 x p
  is_write_verb "$v" || return 0
  local -a OPS=() TG=() SRC=()
  local vflags=""
  case "$v" in
    touch) vflags="-t -d -r -A" ;; mkdir) vflags="-m" ;; truncate) vflags="-s -r" ;;
    cp|mv|ln|install|ditto) vflags="-S -m -o -g -t" ;;
    rsync) vflags="-e --rsh -f --filter --exclude --include --exclude-from --include-from --files-from --log-file -T --temp-dir --partial-dir --chmod" ;;
    sed) vflags="-e -f -l" ;;
    curl) vflags="-o --output -d --data --data-raw --data-binary --data-urlencode -H --header -X --request -u --user -A --user-agent -e --referer -b --cookie -c --cookie-jar -T --upload-file -K --config -m --max-time -w --write-out -x --proxy -F --form --connect-timeout -r --range -C --retry -E --cert --key --cacert" ;;
    wget) vflags="-O -P -o -a -i -e -U --user-agent --header -t -T -w --output-document --directory-prefix --output-file" ;;
    unzip) vflags="-d -x" ;; tar) vflags="-f -C --file --directory -T -X --exclude" ;;
    patch) vflags="-d -i -o -p -r -B -z --directory --input --output" ;;
    zip) vflags="-x -i" ;; sort) vflags="-o -k -t -T -S --output" ;;
  esac
  while [ $j -lt ${#A[@]} ]; do
    a=${A[$j]}; j=$((j+1))
    case "$a" in
      --) while [ $j -lt ${#A[@]} ]; do OPS[${#OPS[@]}]="${A[$j]}"; j=$((j+1)); done ;;
      --*=*) name=${a%%=*}; val=${a#*=}
             case "$v:$name" in
               curl:--output|wget:--output-document|sort:--output|patch:--output|wget:--output-file) [ "$val" = - ] || TG[${#TG[@]}]="$val"; oset=1 ;;
               wget:--directory-prefix|tar:--directory|patch:--directory) tdir=$val ;;
               tar:--file) archive=$val ;;
               sed:--in-place) inplace=1 ;;
               sed:--expression|sed:--file) hasexpr=1 ;;
               cp:--target-directory|mv:--target-directory|ln:--target-directory|install:--target-directory) dest=$val ;;
             esac ;;
      --in-place) [ "$v" = sed ] && inplace=1 ;;
      --remote-name|--remote-header-name) [ "$v" = curl ] && tdir=$SEGDIR ;;
      --extract|--get) [ "$v" = tar ] && mode=x ;;
      --create|--append|--update) [ "$v" = tar ] && mode=c ;;
      -*)
        case " $vflags " in *" $a "*)
          val=${A[$j]}; j=$((j+1))
          case "$v:$a" in
            curl:-o|curl:--output|wget:-O|wget:--output-document|wget:-o|wget:-a|curl:-c|curl:--cookie-jar|sort:-o|sort:--output|patch:-o|patch:--output)
              [ "$val" = - ] || TG[${#TG[@]}]="$val"; oset=1 ;;
            wget:-P|wget:--directory-prefix|unzip:-d|tar:-C|tar:--directory|patch:-d|patch:--directory) tdir=$val ;;
            tar:-f|tar:--file) archive=$val ;;
            cp:-t|mv:-t|ln:-t|install:-t) dest=$val ;;
            sed:-e|sed:-f) hasexpr=1 ;;
          esac
          continue ;;
        esac
        case "$v" in
          sed)  case "$a" in -i*) inplace=1 ;; -[a-zA-Z]*) case "${a#-}" in *i*) inplace=1 ;; esac
                     case "$a" in *e|*f) hasexpr=1; j=$((j+1)) ;; esac ;; esac ;;
          perl) case "${a#-}" in *i*) inplace=1 ;; esac; case "$a" in *e|*E) j=$((j+1)) ;; esac ;;
          curl) case "${a#-}" in *[OJ]*) tdir=$SEGDIR ;; esac
                case "$a" in -[a-zA-Z]*o) TG[${#TG[@]}]="${A[$j]}"; j=$((j+1)) ;; esac ;;
          tar)  case "${a#-}" in *x*) mode=x ;; *[cru]*) mode=c ;; esac
                case "$a" in -[a-zA-Z]*f) archive=${A[$j]}; j=$((j+1)) ;; esac ;;
        esac ;;
      *) OPS[${#OPS[@]}]="$a" ;;
    esac
  done
  # tar's old-style first argument: "tar xzf file.tgz"
  if [ "$v" = tar ] && [ -z "$mode" ] && [ ${#OPS[@]} -gt 0 ]; then
    case "${OPS[0]}" in *[!a-zA-Z]*) ;; *)
      case "${OPS[0]}" in *x*) mode=x ;; *[cru]*) mode=c ;; esac
      case "${OPS[0]}" in *f*) archive=${OPS[1]} ;; esac ;;
    esac
  fi
  local n=${#OPS[@]}
  case "$v" in
    tee|rm|rmdir|unlink|shred|trash|touch|mkdir|truncate|gzip|gunzip|bzip2|xz|unxz|mv) TG=("${TG[@]}" "${OPS[@]}") ;;
    chmod|chown|chgrp) [ $n -gt 1 ] && TG=("${TG[@]}" "${OPS[@]:1}") ;;
    cp|install|ln|rsync|ditto)
      if [ -n "$dest" ]; then TG[${#TG[@]}]="$dest"; SRC=("${OPS[@]}")
      elif [ $n -ge 2 ]; then TG[${#TG[@]}]="${OPS[$((n-1))]}"; SRC=("${OPS[@]:0:$((n-1))}")
      elif [ $n -eq 1 ] && [ "$v" = ln ]; then TG[${#TG[@]}]="${OPS[0]##*/}"; fi ;;
    sed)  [ $inplace = 1 ] || return 0
          if [ $hasexpr = 1 ]; then TG=("${OPS[@]}"); elif [ $n -gt 1 ]; then TG=("${OPS[@]:1}"); fi ;;
    perl) [ $inplace = 1 ] || return 0; TG=("${OPS[@]}") ;;
    dd)   for a in "${A[@]}"; do case "$a" in of=*) TG[${#TG[@]}]="${a#of=}" ;; esac; done ;;
    curl) [ -n "$tdir" ] && TG[${#TG[@]}]="$tdir" ;;
    wget) [ $oset = 1 ] || TG[${#TG[@]}]="${tdir:-$SEGDIR}" ;;
    unzip) TG[${#TG[@]}]="${tdir:-$SEGDIR}" ;;
    tar)  if [ "$mode" = x ]; then TG[${#TG[@]}]="${tdir:-$SEGDIR}"
          elif [ "$mode" = c ] && [ -n "$archive" ] && [ "$archive" != - ]; then TG[${#TG[@]}]="$archive"; fi ;;
    patch) TG[${#TG[@]}]="${tdir:-$SEGDIR}"; [ $n -gt 0 ] && TG[${#TG[@]}]="${OPS[0]}" ;;
    zip)  [ $n -gt 0 ] && TG[${#TG[@]}]="${OPS[0]}" ;;
  esac
  case "$v" in rm|rmdir|unlink|shred|trash|mv|chmod|chown|chgrp|rsync|unzip|tar|gzip|gunzip|bzip2|xz|unxz|truncate|patch) destructive=1 ;; esac
  # Sources that are, or contain, an APPROVED file would plant a fake approval.
  for a in "${SRC[@]}"; do
    p=$(abspath "$a" "$SEGDIR")
    [ "$(lower "${p##*/}")" = approved ] && block self-protect "copying an APPROVED file is not allowed."
    [ -d "$p" ] && [ -n "$(find "$p" -iname APPROVED -print 2>/dev/null | head -n 1)" ] && block self-protect "$p contains an APPROVED file."
  done
  for a in "${TG[@]}"; do
    [ -n "$a" ] || continue
    case "$a" in *'$'*|*'`'*) block repo-write "$v target '$a' is not a fixed path; cannot check it." ;; esac
    local -a XS=()
    case "$a" in *[*?[]*)
      while IFS= read -r x; do [ -n "$x" ] && XS[${#XS[@]}]="$x"; done <<EOF
$(cd "$SEGDIR" 2>/dev/null && compgen -G "$a" 2>/dev/null)
EOF
    ;; esac
    [ ${#XS[@]} -gt 0 ] || XS=("$a")
    for x in "${XS[@]}"; do
      p=$(abspath "$x" "$SEGDIR")
      is_secret_name "$p" && block secret "$v on secret file $p."
      check_write "$p" "$SEGDIR"
      if [ $destructive = 1 ]; then
        protected_inside "$p" && block self-protect "$v $p: $PROT_WHY."
      fi
      case "$v" in unzip|tar|patch) under "$p" "$DOCS/dev" && block self-protect "extracting into atreya-docs/dev/ could create an APPROVED file." ;; esac
    done
  done
  return 0
}

# xargs: the file list arrives on stdin, so targets are unknown.
xargs_check() {
  local c="$1" a s
  if is_write_verb "$c"; then
    under "$SEGDIR" "$DOCS" || under "$SEGDIR" "$QA" || under "$SEGDIR" /private/tmp \
      || block repo-write "xargs $c takes its targets from stdin; only allowed with cwd in atreya-docs/, atreya-qa/ or /tmp."
    return 0
  fi
  case "$c" in
    grep|egrep|fgrep|rg)
      for a in "${A[@]}"; do case "$a" in --files-with-matches|--count|-[a-zA-Z]*) case "$a" in --*|-*[lLcq]*) return 0 ;; esac ;; esac; done ;;
    cat|head|tail|less|more|strings|xxd|od|hexdump|base64|awk|sed|cut|sort|uniq|diff|cmp|nl|tac|rev|jq|plutil) ;;
    *) return 0 ;;
  esac
  too_broad "$SEGDIR" && block secret "xargs $c reads files from stdin; $SEGDIR is too broad to check for secrets."
  s=$(secret_under "$SEGDIR")
  [ -n "$s" ] && block secret "xargs $c reads files listed on stdin and $SEGDIR contains secret file $s."
  return 0
}

handle_bash() {
  local t k=0 w
  CMD=$(jget .tool_input.command)
  [ -n "$CMD" ] || block parse "Bash call without a command."
  # rule a: any word of the raw command (also inside quotes, URLs, KEY=path,
  # REV:path, @file) that is a secret file name blocks.
  local SEPCH=$' \t\n;|&<>()`"\'=:@,{}'
  while IFS= read -r t; do
    [ -n "$t" ] && is_secret_name "$t" && block secret "command references secret file '$t' (.env/.jks/keystore/firebase-*.json/google-services/GoogleService-Info.plist/gchat_logger.dart/flavor_config.dart). .env.example is fine."
  done <<EOF
$(printf '%s' "$CMD" | tr -s "$SEPCH" '\n')
EOF
  analyze_bash "$CMD" "$CWD"
  while [ $k -lt ${#SUBQ[@]} ]; do
    [ $k -lt 20 ] || block parse "too many nested commands to check."
    analyze_bash "${SUBQ[$k]}" "${SUBQD[$k]}"; k=$((k+1))
  done
  # rule f: network clients / interpreters must not reach a production host.
  # (grep/git/sed etc. may still mention the host, e.g. code searches.)
  if host_hit "$CMD"; then
    for w in $CMDWORDS; do
      case "$w" in curl|wget|http|https|xh|httpie|nc|ncat|telnet|lynx|links|w3m|open|aria2c|ssh|scp|sftp|rsync|ftp|node|npx|python|python3|php|ruby|perl|deno|bun|playwright|osascript|chrome|chromium)
        block prod-host "$w with production host $HOST_HIT; use staging." ;; esac
    done
  fi
  pass
}

# ================================================================ dispatch
case "$TOOL" in
  Bash) handle_bash ;;
  Read|Edit|Write|MultiEdit|NotebookEdit) handle_file_tool ;;
  Grep) handle_grep ;;
  Glob) handle_glob ;;
  *) handle_mcp_and_web ;;
esac
pass
