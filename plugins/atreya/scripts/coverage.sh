#!/bin/bash
# coverage.sh [--root R]
#
# Checks the CURRENT atreya-docs/modules.yaml against the current _map data:
# every backend route in exactly one module or unassigned, no unknown
# controllers/routes. Writes nothing. Exit 1 on conflicts or errors.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
[ -f "$DOCS/modules.yaml" ] || die "no $DOCS/modules.yaml yet (run /atreya:map --merge)"
exec bash "$ATREYA_SCRIPTS/build-modules.sh" --root "$ROOT" --from "$DOCS/modules.yaml"
