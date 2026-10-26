#!/bin/bash
# atreya SessionStart banner: one line for the user via "systemMessage".
# WHY systemMessage: the user sees it, but it is not added to Claude's context,
# so it costs no tokens. A banner can never block anything, so on any error it
# still prints a line (with "?" for what it could not read) and exits 0.
ROOT_DIR=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
VER=$(/usr/bin/jq -r '.version // "?"' "$ROOT_DIR/.claude-plugin/plugin.json" 2>/dev/null) || VER="?"
WS=${CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT:-$HOME/Mohini/atreya-ai}
case "$WS" in "~"|"~/"*) WS="$HOME${WS#\~}" ;; esac
NOTE=""; [ -d "$WS" ] || NOTE=" (NOT FOUND, set workspace_root in /config)"
SHOW=$WS; case "$WS" in "$HOME"/*) SHOW="~${WS#"$HOME"}" ;; esac
MSG="atreya v${VER:-?} | workspace ${SHOW}${NOTE} | repos read-only"
MSG=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"systemMessage":"%s"}\n' "$MSG"
exit 0
