#!/bin/bash
# Shared secret filter (patterns live in redact.awk next to this file).
#
#   some-command | bash redact.sh        mask secrets in a stream
#   . redact.sh; ... | redact            same, as a function
#   . redact.sh; secret_scan FILE...     report FILE LINE TYPE CONFIDENCE COMMENTED
#                                        (never the value)
ATREYA_REDACT_AWK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/redact.awk"
redact()      { awk -v mode=redact -f "$ATREYA_REDACT_AWK"; }
secret_scan() { awk -v mode=scan -f "$ATREYA_REDACT_AWK" "$@"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then redact; fi
