#!/bin/bash
# yaml2json.sh FILE                  strict YAML subset -> JSON on stdout
# yaml2json.sh --front-matter FILE   same, for the "---" block at the top of a .md
#
# WHY a strict subset: stock macOS has no YAML parser, and modules.yaml is the
# single source of truth. Anything outside the subset fails with the line number
# instead of being guessed. Subset (see references/modules-schema.md):
#   - 2-space indentation, spaces only; mappings "key: value" / "key:" + block
#   - lists "- value" or "- key: value" (list of mappings), indented under the key
#   - values: plain, "double quoted" (\" \\ \n \t), 'single quoted' (''), [] , {}
#   - true/false -> boolean, null/~ -> null, everything else -> string
#   - full-line comments and " # comment" after a value; blank lines
#   - NOT allowed: tabs, flow lists/maps with content, anchors/aliases, tags,
#     multi-line (| >) values, "? " keys, duplicate keys, plain values with ": "
JQ=/usr/bin/jq
FM=0; [ "$1" = --front-matter ] && { FM=1; shift; }
F="$1"
[ -n "$F" ] && [ -f "$F" ] || { echo "yaml2json: file not found: $F" >&2; exit 1; }

if [ $FM = 1 ]; then
  [ "$(head -n 1 "$F" | tr -d '\r')" = "---" ] || { echo "yaml2json: $F:1: no front matter (first line must be ---)" >&2; exit 1; }
  END=$(awk 'NR > 1 && /^---[ \t\r]*$/ { print NR; exit }' "$F")
  [ -n "$END" ] || { echo "yaml2json: $F: front matter not closed with ---" >&2; exit 1; }
  BODY=$(sed -n "2,$((END - 1))p" "$F"); OFFSET=1
else
  BODY=$(cat "$F"); OFFSET=0
fi

JSON=$(printf '%s\n' "$BODY" | awk -v FN="$F" -v OFF="$OFFSET" '
function err(m) { printf "yaml2json: %s:%d: %s\n", FN, NR + OFF, m > "/dev/stderr"; failed = 1; exit 1 }
function jstr(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return "\"" s "\"" }
function open(t, ind) { depth++; st_type[depth] = t; st_ind[depth] = ind; st_n[depth] = 0; st_id[depth] = ++ids; printf "%s", (t == "map" ? "{" : "[") }
function close_() { printf "%s", (st_type[depth] == "map" ? "}" : "]"); depth-- }
function sep() { if (st_n[depth]++ > 0) printf "," }
function is_entry(s) { return s ~ /^[A-Za-z_][A-Za-z0-9_-]*:( |$)/ }
function is_item(s) { return s ~ /^-( |$)/ }

# value text -> JSON (or error). Handles quotes, comments, empty collections.
function scalar(r,   q, i, c, out, rest) {
  if (r ~ /^"/) {
    out = ""; i = 2
    while (i <= length(r)) {
      c = substr(r, i, 1)
      if (c == "\\") {
        c = substr(r, i + 1, 1)
        if (c == "\"" || c == "\\") out = out c
        else if (c == "n") out = out "\001"
        else if (c == "t") out = out "\t"
        else err("unsupported escape \\" c " in double-quoted value")
        i += 2; continue
      }
      if (c == "\"") break
      out = out c; i++
    }
    if (i > length(r)) err("unterminated double-quoted value")
    rest = substr(r, i + 1)
    if (rest !~ /^[ ]*$/ && rest !~ /^[ ]+#/) err("text after closing quote")
    return jstr_nl(out)
  }
  if (r ~ /^\047/) {
    out = ""; i = 2
    while (i <= length(r)) {
      c = substr(r, i, 1)
      if (c == "\047") { if (substr(r, i + 1, 1) == "\047") { out = out "\047"; i += 2; continue } break }
      out = out c; i++
    }
    if (i > length(r)) err("unterminated single-quoted value")
    rest = substr(r, i + 1)
    if (rest !~ /^[ ]*$/ && rest !~ /^[ ]+#/) err("text after closing quote")
    return jstr(out)
  }
  sub(/[ ]+#.*$/, "", r); sub(/[ ]+$/, "", r)
  if (r == "[]" || r == "{}") return r
  if (r ~ /^[\[\]{}&*!|>%@`]/) err("unsupported YAML syntax (flow list/map, anchor, alias, tag or block value); quote the value")
  if (r ~ /^\? / || r ~ /^- /) err("unsupported YAML syntax")
  if (r ~ /: / || r ~ /:$/) err("plain value contains \": \"; put it in double quotes")
  if (r == "true" || r == "false") return r
  if (r == "null" || r == "~") return "null"
  return jstr(r)
}
# \001 marks a newline from a "\n" escape; JSON needs it as \n.
function jstr_nl(s) { s = jstr(s); gsub(/\001/, "\\n", s); return s }

function entry(c, ind,   key, rest) {
  key = c; sub(/:.*/, "", key)
  rest = substr(c, length(key) + 2); sub(/^[ ]+/, "", rest)
  if ((st_id[depth], key) in seen) err("duplicate key \"" key "\"")
  seen[st_id[depth], key] = 1
  printf "%s:", jstr(key)
  if (rest == "" || rest ~ /^#/) { pend = 1; pend_ind = ind } else printf "%s", scalar(rest)
}

{
  sub(/\r$/, "")
  if ($0 ~ /^[ ]*\t/ || $0 ~ /^\t/) err("tab in indentation; use spaces")
  if ($0 ~ /^[ ]*$/ || $0 ~ /^[ ]*#/) next
  match($0, /^ */); ind = RLENGTH; c = substr($0, ind + 1)
  if (ind % 2) err("indentation must be a multiple of 2 spaces")
  if (depth == 0) {
    if (is_item(c)) err("top level must be a mapping (key: value), not a list")
    if (ind != 0) err("top level must start at column 1")
    open("map", 0)
  }
  if (pend) {
    pend = 0
    if (ind > pend_ind) open(is_item(c) ? "seq" : "map", ind)
    else printf "null"
  }
  while (depth > 0 && ind < st_ind[depth]) close_()
  if (depth == 0) err("bad indentation")
  if (ind != st_ind[depth]) err("bad indentation: expected " st_ind[depth] " spaces, got " ind)
  if (st_type[depth] == "seq") {
    if (!is_item(c)) err("expected a list item (\"- ...\") at this indentation")
    r = (c == "-") ? "" : substr(c, 3)
    sub(/^[ ]+/, "", r)
    if (r == "" || r ~ /^#/) err("empty list item")
    sep()
    if (is_entry(r)) { open("map", ind + 2); sep(); entry(r, ind + 2) } else printf "%s", scalar(r)
  } else {
    if (is_item(c)) err("list item must be indented under its key")
    if (!is_entry(c)) err("expected \"key: value\" (keys: letters, digits, _ and -)")
    sep(); entry(c, ind)
  }
}
END {
  if (failed) exit 1
  if (depth == 0) { printf "{}"; exit 0 }
  if (pend) printf "null"
  while (depth > 0) close_()
}') || exit 1

printf '%s' "$JSON" | "$JQ" . 2>/dev/null || { echo "yaml2json: $F: internal error: produced invalid JSON" >&2; exit 1; }
