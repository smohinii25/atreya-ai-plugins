#!/bin/bash
# seed-docs.sh [--root R]
#
# First drafts of the human-owned docs, created ONLY if missing (never
# overwrites; prints "kept" for existing files):
#   environments.md     from references/environments-template.md (all TO FILL)
#   external-systems.md where each known system is used (file:line from
#                       _map/*/externals.json), purpose "Needs confirmation"
#   not-in-use.md       the two confirmed items + script-found candidates
# glossary.md is written by Claude in the map skill (domain terms TO CONFIRM).
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
mkdir -p "$DOCS" || die "cannot create $DOCS"
DATE=$(today)
keep() { [ -f "$DOCS/$1" ] && { echo "kept $DOCS/$1 (exists, not touched)"; return 0; }; return 1; }

keep environments.md || { cp "$ATREYA_PLUGIN/references/environments-template.md" "$DOCS/environments.md" && echo "wrote $DOCS/environments.md"; }

if ! keep external-systems.md; then
  {
    echo "# External systems"
    echo
    echo "Status: **Draft** · $DATE · built from \`_map/*/externals.json\` (file and line only)."
    echo "Purpose and environments: **Needs confirmation** for every row. No keys or URLs from secret files."
    echo
    for f in "$DOCS"/_map/*/externals.json; do [ -f "$f" ] && cat "$f"; done | "$JQ" -s -r '
      ([.[] | .repo as $r | .commit as $c | .systems[] | . + {repo: $r, commit: $c}]) as $all |
      (["Razorpay", "ENACH", "Interakt (WhatsApp)", "ZeptoMail", "Firebase", "S3", "AWS Lambda / API Gateway", "Samvit Chakra"]) as $order |
      ($order[] as $s |
        "## \($s)\n", "Purpose: Needs confirmation. Environments: Needs confirmation.\n",
        (if ([$all[] | select(.system == $s)] | length) == 0 then "Not found in code.\n" else
          ("| Repo | Files | Where (file:lines) |", "|---|---|---|",
           ($all[] | select(.system == $s) | "| \(.repo) | \(.files | length) | \(.files[0:8] | map("`\(.file):\(.lines[0:5] | map(tostring) | join(","))`") | join("<br>"))\(if (.files | length) > 8 then "<br>…and \((.files | length) - 8) more" else "" end) |"), "")
        end)),
      "## Other third-party hosts in code (candidates)\n",
      "Host names only, most used first. Needs confirmation whether each is an integration.\n",
      "| Repo | Host | Mentions |", "|---|---|---|",
      (.[] | .repo as $r | .other_hosts[0:15][] | "| \($r) | `\(.host)` | \(.count) |")'
  } > "$DOCS/external-systems.md" && echo "wrote $DOCS/external-systems.md"
fi

if ! keep not-in-use.md; then
  {
    echo "# Not in use"
    echo
    echo "Status: **Draft** · $DATE. Each item is **Confirmed** (a human said so) or **Needs confirmation** (found by a script)."
    echo
    echo "## Confirmed"
    echo
    echo "| Feature | Where | Status | Note |"
    echo "|---|---|---|---|"
    echo "| Receptionist | Backend routes \`reception/*\`, \`reception-api/*\`; Frontend \`ReceptionistController\` routes | Confirmed | Not used on web or mobile. |"
    echo "| Research dashboard | Backend \`research*\` routes; Frontend \`ResearchDashboardController\` routes | Confirmed | Production only links to another website. |"
    echo
    echo "## Candidates (Needs confirmation)"
    echo
    if [ -f "$DOCS/modules.yaml" ]; then
      bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml" | "$JQ" -r '
        (.unassigned_routes // []) as $u |
        if ($u | length) == 0 then empty else
          "### \(.backend): backend routes in no module (\($u | length))\n",
          ($u | group_by(split(" ")[1] | split("/")[0]) | .[] |
            "- `\(.[0] | split(" ")[1] | split("/")[0] | if . == "" then "/" else . end)`: \(map("`\(.)`") | join(", ")): Needs confirmation"),
          "" end'
    fi
    for f in "$DOCS"/_map/*/routes.json; do [ -f "$f" ] && "$JQ" -r '
      (.routes | map(select(.shadowed))) as $sh |
      (if ($sh | length) > 0 then "### \(.repo): shadowed duplicate routes (an earlier definition is overridden)\n", ($sh[] | "- `\(.key)` at `\(.file):\(.line)`: Needs confirmation"), "" else empty end),
      (if .counts.commented_out_lines > 0 then "### \(.repo): \(.counts.commented_out_lines) commented-out route lines in routes/*.php\n", "Needs confirmation whether these features were removed.\n" else empty end)' "$f"; done
    for f in "$DOCS"/_map/*/screens.json; do [ -f "$f" ] && "$JQ" -r 'select(.kind == "flutter") |
      ([.screens[] | select((.routes | length) == 0)]) as $nr |
      (if ($nr | length) > 0 then "### \(.repo): screen classes with no GoRoute\n", ($nr[] | "- \(.id) (`\(.file // "file not found")`): Needs confirmation"), "" else empty end)' "$f"; done
    echo "More candidates (routes no screen calls) are added by /atreya:link-apis."
  } > "$DOCS/not-in-use.md" && echo "wrote $DOCS/not-in-use.md"
fi
