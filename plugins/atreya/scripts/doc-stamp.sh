#!/bin/bash
# doc-stamp.sh [--root R] MODULE_ID DOC [TICKET]  (DOC: BRD | PRD | staging-delta | impact)
#
# Prints the front-matter stamp for a new doc (references/doc-control.md):
# module, doc, status Draft, today's date, reviewer TBD, and the CURRENT HEAD
# commit of every repo the module touches (from modules.yaml).
# impact: MODULE_ID may be a comma list ("auth,patients": the repos of all of
# them) and TICKET (Zoho Sprints item id or adhoc-<slug>) is required.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
ID="${ARGS[0]:-}"; DOC="${ARGS[1]:-}"; TICKET="${ARGS[2]:-}"
case "$DOC" in BRD|PRD|staging-delta|impact) ;; *) die "usage: doc-stamp.sh --root R MODULE_ID BRD|PRD|staging-delta|impact [TICKET]" ;; esac
case "$ID" in *,*) [ "$DOC" = impact ] || die "a module list is only for impact docs" ;; esac
if [ "$DOC" = impact ]; then case "$TICKET" in ""|*[!A-Za-z0-9._-]*) die "impact needs a TICKET (letters, digits, . _ -)" ;; esac; fi
[ -f "$DOCS/modules.yaml" ] || die "no modules.yaml"
REPOS=$(bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml" | "$JQ" -r --arg ids "$ID" '
  ($ids | split(",")) as $want | . as $root |
  [$want[] as $id | ($root.modules[] | select(.id == $id))] as $ms |
  if ($ms | length) != ($want | length) then error("unknown module") else
  ([$ms[] | .repos[].repo, .screens[].repo, .web_routes[].repo] + [.backend] | unique[]) end') || die "unknown module in $ID"
printf -- '---\nmodule: "%s"\ndoc: "%s"\nstatus: "Draft"\ndate: "%s"\nreviewer: "TBD"\n' "$ID" "$DOC" "$(today)"
[ -z "$TICKET" ] || printf 'ticket: "%s"\n' "$TICKET"
printf 'commits:\n'
for r in $REPOS; do printf '  %s: "%s"\n' "$r" "$(repo_stamp "$(repo_dir "$r")")"; done
printf -- '---\n'
