#!/bin/bash
# secret-scan.sh [--root R] [--out FILE]
#
# One-time, read-only scan of every TRACKED file in <root>/repos/* for
# key-like strings. Writes <root>/atreya-docs/security/secret-scan.md with
# file, line and key TYPE only. Values are never printed or written.
# Guarded secret files (.env, keystores, flavor_config.dart, ...) are NOT
# opened; they are listed by name as "already guarded".
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
OUT="$DOCS/security/secret-scan.md"
[ "${ARGS[0]}" = --out ] && OUT="${ARGS[1]}"
mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/atreya-scan.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/findings.tsv"; : > "$TMP/guarded.tsv"; : > "$TMP/repos.tsv"

# Binary / media / vendored-minified files: skipped (not text secrets).
SKIP_RE='\.(png|jpe?g|gif|webp|ico|bmp|svg|pdf|ttf|otf|woff2?|eot|mp3|mp4|mov|wav|zip|gz|tgz|jar|aar|so|a|dylib|apk|ipa|lottie|riv|db|sqlite|min\.js|min\.css|map|lock)$'

for d in "$ROOT"/repos/*/; do
  d=${d%/}; name=${d##*/}
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || continue
  printf '%s\t%s\n' "$name" "$(repo_stamp "$d")" >> "$TMP/repos.tsv"
  all="$TMP/$name.all"; git -C "$d" ls-files > "$all"
  # guarded files: names only
  awk "$ATREYA_SECRET_FILTER" "$all" > "$TMP/$name.safe"
  grep -vxF -f "$TMP/$name.safe" "$all" | sed "s#^#$name	#" >> "$TMP/guarded.tsv"
  # scan the rest (text only, < 5 MB), relative paths, from inside the repo
  grep -viE "$SKIP_RE" "$TMP/$name.safe" | while IFS= read -r f; do
    [ -f "$d/$f" ] || continue
    [ "$(wc -c < "$d/$f")" -lt 5242880 ] || continue
    printf '%s\0' "$f"
  done | (cd "$d" && xargs -0 awk -v mode=scan -f "$ATREYA_REDACT_AWK" 2>/dev/null) \
       | sed "s#^#$name	#" >> "$TMP/findings.tsv"
done

total=$(grep -c . "$TMP/findings.tsv")
high=$(awk -F '\t' '$5 == "high"' "$TMP/findings.tsv" | grep -c .)
{
  echo "# Secret scan (read-only)"
  echo
  echo "- Date: $(today)"
  echo "- Scope: every tracked file in repos/ (git ls-files), text files under 5 MB"
  echo "- Values are never shown. Only file, line and key type."
  echo "- Status: **Needs confirmation**: each finding must be checked and, if real, rotated by the owner."
  echo
  echo "| Repo | Commit scanned |"; echo "|---|---|"
  awk -F '\t' '{ printf "| %s | `%s` |\n", $1, $2 }' "$TMP/repos.tsv"
  echo
  echo "## Summary"
  echo
  echo "$total findings ($high high confidence)."
  echo
  echo "| Key type | Confidence | Findings | Files |"; echo "|---|---|---|---|"
  awk -F '\t' '{ k = $4 "\t" $5; n[k]++; if (!((k, $1 "/" $2) in s)) { s[k, $1 "/" $2] = 1; f[k]++ } }
    END { for (k in n) { split(k, a, "\t"); printf "| %s | %s | %d | %d |\n", a[1], a[2], n[k], f[k] } }' "$TMP/findings.tsv" | sort
  echo
  echo "## Candidate files to add to the guard"
  echo
  echo "Files with at least one **high-confidence** finding that the guard does not block yet."
  echo "Proposal only: nothing changes until approved."
  echo
  echo "| Repo | File | High findings | Types |"; echo "|---|---|---|---|"
  awk -F '\t' '$5 == "high" { k = $1 "\t" $2; n[k]++; if (!((k, $4) in s)) { s[k, $4] = 1; t[k] = t[k] (t[k] ? ", " : "") $4 } }
    END { for (k in n) { split(k, a, "\t"); printf "| %s | `%s` | %d | %s |\n", a[1], a[2], n[k], t[k] } }' "$TMP/findings.tsv" | sort
  echo
  echo "## All findings"
  echo
  echo "| Repo | File | Line | Type | Confidence | Commented out |"; echo "|---|---|---|---|---|---|"
  sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3n "$TMP/findings.tsv" \
    | awk -F '\t' '{ printf "| %s | `%s` | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6 }'
  echo
  echo "## Already guarded (not opened by this scan)"
  echo
  echo "| Repo | File |"; echo "|---|---|"
  sort "$TMP/guarded.tsv" | awk -F '\t' '{ printf "| %s | `%s` |\n", $1, $2 }'
} > "$OUT"

echo "secret scan: $total findings ($high high confidence) in $(grep -c . "$TMP/repos.tsv") repos; $(grep -c . "$TMP/guarded.tsv") guarded files not opened"
echo "report: $OUT"
