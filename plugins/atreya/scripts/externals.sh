#!/bin/bash
# externals.sh [--root R] REPO
#
# Where each known external system is used in code: file and line numbers only
# (matched text is never output, so no key or URL from code can leak). Also
# lists other third-party hosts found in code as candidates. Guarded files are
# never opened. Writes _map/<REPO>/externals.json.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"; mkdir -p "$OUTD" || die "cannot create $OUTD"
COMMIT=$(repo_stamp "$REPO")

# Code only: skip media, lock files, minified bundles and vendored libraries.
SKIP='\.(png|jpe?g|gif|webp|ico|svg|pdf|ttf|otf|woff2?|eot|mp3|mp4|zip|gz|jar|lock|min\.js|min\.css|map)$|(^|/)(vendor|node_modules|public/(vendor|plugins|assets/vendor|libs?))/|package-lock\.json$'
LIST=$(tracked_files "$REPO" | grep -viE "$SKIP")

# system<TAB>case-insensitive ERE
SYSTEMS='Razorpay	razorpay
ENACH	enach|e-nach|e_nach|paynimo|e-?mandate
Interakt (WhatsApp)	interakt
ZeptoMail	zeptomail
Firebase	firebase|kreait|fcm\.googleapis
S3	s3client|storage::disk\(["'"'"']s3|s3\.amazonaws|s3\.[a-z0-9-]+\.amazonaws|uploadfiletos3|amazons3
AWS Lambda / API Gateway	lambda-url\.|execute-api\.|aws\\\\lambda|lambdaclient
Samvit Chakra	samvit'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/atreya-ext.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$LIST" | tr '\n' '\0' > "$TMP/files0"
: > "$TMP/hits.tsv"
printf '%s\n' "$SYSTEMS" | while IFS='	' read -r sys re; do
  # grep prints file:line:text; text is dropped right here, inside the pipe.
  (cd "$REPO" && xargs -0 grep -nHiE -- "$re" < "$TMP/files0" 2>/dev/null) \
    | awk -F: -v s="$sys" '{ print s "\t" $1 "\t" $2 }' >> "$TMP/hits.tsv"
done
# Other hosts: host names only, from URLs in code.
(cd "$REPO" && xargs -0 grep -hoiE 'https?://[a-z0-9.-]+\.[a-z]{2,}' < "$TMP/files0" 2>/dev/null) \
  | sed -E 's#^https?://##' | tr 'A-Z' 'a-z' | sort | uniq -c \
  | awk '{ print $2 "\t" $1 }' > "$TMP/hosts.tsv"

JSON=$("$JQ" -R -s --arg repo "$NAME" --arg commit "$COMMIT" --rawfile hosts "$TMP/hosts.tsv" '
  split("\n") | map(select(length > 0) | split("\t")) as $rows |
  ($hosts | split("\n") | map(select(length > 0) | split("\t") | {host: .[0], count: (.[1] | tonumber)})) as $h |
  def known: test("(^|\\.)(ashoka\\.world|naditarangini\\.com|atreyainnovations\\.com)$");
  def library: test("(w3\\.org|schemas\\.|xmlsoap|apache\\.org|github|githubusercontent|gitlab|packagist|npmjs|yarnpkg|pub\\.dev|dart\\.dev|flutter\\.dev|php\\.net|laravel\\.com|symfony|getcomposer|jquery|bootstrapcdn|cloudflare|jsdelivr|unpkg|cdnjs|fonts\\.googleapis|fonts\\.gstatic|gstatic|example\\.|localhost|127\\.0|purl\\.org|creativecommons|mozilla\\.org|apple\\.com|android\\.com|microsoft\\.com|opensource\\.org|tidelift|opencollective|feross|nette\\.org|php-fig|doctrine-project|colinodell|swagger|openapis)");
  ($rows | group_by(.[0]) | map({
      system: .[0][0],
      matches: length,
      files: (group_by(.[1]) | map({file: .[0][1], lines: (map(.[2] | tonumber) | unique)}) | sort_by(.file))
    }) | sort_by(.system)) as $sys |
  {repo: $repo, commit: $commit,
   note: "file and line numbers only; matched text is never stored",
   systems: $sys,
   other_hosts: ([$h[] | select((.host | known | not) and (.host | library | not))] | sort_by(-.count, .host))}' < "$TMP/hits.tsv") || die "could not build externals.json"
printf '%s\n' "$JSON" > "$OUTD/externals.json"
printf '%s' "$JSON" | "$JQ" -r '"externals: \(.repo) @ \(.commit[0:10]): " + (.systems | map("\(.system) \(.files | length) files") | join(", ")) + "; \(.other_hosts | length) other hosts"'
echo "wrote $OUTD/externals.json"
