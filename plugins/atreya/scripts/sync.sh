#!/bin/bash
# sync.sh [--root R] [--module ID] [DOC...]
#
# Which docs and diagrams are out of date with the code. For each doc (default:
# nt/<id>/PRD.md, BRD.md, staging-delta.md and diagrams/*.drawio of every module,
# or of --module ID; or the DOC paths given) it reads the commit stamp (front
# matter `commits`, or the drawio `atreya_commits`) and asks git, per repo:
#   git log <stamp>..HEAD -- <files>
#   STALE    commits changed the module's own files (modules.yaml: repos[].files,
#            repos[].paths, screens); for a diagram: the files its boxes and
#            arrows cite (atreya_source), except route files
#   CHECK    only shared files changed (route files, the App router, migrations
#            of the module's tables): the module may or may not be affected
#   OK       nothing changed since the stamp
#   UNKNOWN  no stamp for a repo of the module, or the stamp commit is not in
#            the repo's history
# Also warns when _map/ is behind a repo's HEAD (refresh the map first).
# Read-only: uses only `git log` (names and subjects, never file contents).
# impact docs (dev/) are not checked: they describe one change at one moment.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
MOD=""; DOCLIST=()
set -- "${ARGS[@]}"
while [ $# -gt 0 ]; do case "$1" in --module) MOD="$2"; shift 2 ;; -*) die "unknown argument $1" ;; *) DOCLIST+=("$1"); shift ;; esac; done
[ -f "$DOCS/modules.yaml" ] || die "no modules.yaml (run /atreya:map --merge)"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/atreya-sync.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT
bash "$ATREYA_SCRIPTS/yaml2json.sh" "$DOCS/modules.yaml" > "$TMPD/modules.json" || die "modules.yaml does not parse"
[ -z "$MOD" ] || "$JQ" -e --arg m "$MOD" '.modules | any(.id == $m)' "$TMPD/modules.json" >/dev/null || die "unknown module $MOD"
BACKEND=$("$JQ" -r '.backend' "$TMPD/modules.json")

# ---- docs to check
if [ ${#DOCLIST[@]} -eq 0 ]; then
  for m in $("$JQ" -r --arg m "$MOD" '.modules[] | select($m == "" or .id == $m) | .id' "$TMPD/modules.json"); do
    for d in PRD.md BRD.md staging-delta.md; do [ -f "$DOCS/nt/$m/$d" ] && DOCLIST+=("$DOCS/nt/$m/$d"); done
    for d in "$DOCS/nt/$m"/diagrams/*.drawio; do [ -f "$d" ] && DOCLIST+=("$d"); done
  done
fi
[ ${#DOCLIST[@]} -gt 0 ] || { echo "sync: no docs to check${MOD:+ for $MOD}"; exit 0; }

# ---- map freshness
BEHIND=""
for d in "$DOCS"/_map/*/; do
  r=$(basename "$d"); [ "$r" = _modules ] && continue; [ -d "$ROOT/repos/$r" ] || continue
  c=$( { "$JQ" -r '.commit // empty' "$d/routes.json" 2>/dev/null || "$JQ" -r '.commit // empty' "$d/screens.json" 2>/dev/null; } | head -n 1)
  h=$(git -C "$ROOT/repos/$r" rev-parse HEAD 2>/dev/null)
  [ -n "$c" ] && [ "$c" != "$h" ] && BEHIND="$BEHIND$r "
done

# files LIST for one module and repo: own (o) or shared (s), one per line
mod_files() { # MODULE REPO o|s
  if [ "$3" = o ]; then
    "$JQ" -r --arg m "$1" --arg r "$2" '.modules[] | select(.id == $m) | ([.repos[] | select(.repo == $r) | .files[], .paths[]] + [.screens[] | select(.repo == $r) | .path]) | unique[]' "$TMPD/modules.json"
  else
    [ -f "$DOCS/_map/$2/routes.json" ] && "$JQ" -r '.route_files[]?.file' "$DOCS/_map/$2/routes.json"
    [ -f "$DOCS/_map/$2/screens.json" ] && "$JQ" -r '.router // empty' "$DOCS/_map/$2/screens.json"
    [ -f "$DOCS/_map/$2/models.json" ] && "$JQ" -r --slurpfile M "$TMPD/modules.json" --arg m "$1" '
      ([$M[0].modules[] | select(.id == $m) | .tables[]]) as $t | .tables[] | select(.name as $n | $t | index($n)) | .migrations[]?' "$DOCS/_map/$2/models.json"
  fi | sort -u
}

NOK=0; NSTALE=0; NCHECK=0; NUNK=0
for doc in "${DOCLIST[@]}"; do
  case "$doc" in /*) ;; *) doc="$ROOT/$doc" ;; esac
  [ -f "$doc" ] || die "no such doc: $doc"
  rel=${doc#"$DOCS/"}
  case "$doc" in
    *.drawio)
      st=$(grep -o '<UserObject id="atreya-stamp"[^>]*>' "$doc" | head -n 1)
      m=$(printf '%s' "$st" | sed -n 's/.*atreya_module="\([^"]*\)".*/\1/p')
      printf '%s' "$st" | sed -n 's/.*atreya_commits="\([^"]*\)".*/\1/p' | tr ';' '\n' | awk -F= 'NF == 2 { print $1 "\t" $2 }' > "$TMPD/stamp.tsv"
      name=$(basename "$doc" .drawio); refresh="make-diagram.sh $m --rerun $name" ;;
    *.md)
      fm=$(bash "$ATREYA_SCRIPTS/yaml2json.sh" --front-matter "$doc" 2>/dev/null) || fm='{}'
      m=$(printf '%s' "$fm" | "$JQ" -r '.module // ""')
      printf '%s' "$fm" | "$JQ" -r '(.commits // {}) | to_entries[] | "\(.key)\t\(.value)"' > "$TMPD/stamp.tsv"
      case "$(printf '%s' "$fm" | "$JQ" -r '.doc // ""')" in
        PRD) refresh="/atreya:prd $m" ;; BRD) refresh="/atreya:brd $m" ;; staging-delta) refresh="staging-delta.sh $m" ;; *) refresh="(unknown doc type)" ;; esac ;;
    *) die "not a doc or diagram: $doc" ;;
  esac
  "$JQ" -e --arg m "$m" '.modules | any(.id == $m)' "$TMPD/modules.json" >/dev/null 2>&1 || { echo "UNKNOWN  $rel: module '$m' is not in modules.yaml"; NUNK=$((NUNK+1)); continue; }
  REPOS=$("$JQ" -r --arg m "$m" --arg be "$BACKEND" '.modules[] | select(.id == $m) | [.repos[].repo, .screens[].repo, .web_routes[].repo, $be] | unique[]' "$TMPD/modules.json")
  status=OK; detail=""
  for r in $REPOS; do
    [ -d "$ROOT/repos/$r" ] || continue
    s=$(awk -F'\t' -v r="$r" '$1 == r { print $2 }' "$TMPD/stamp.tsv")
    if [ -z "$s" ]; then status=UNKNOWN; detail="$detail  $r: no commit in the stamp\n"; continue; fi
    h=$(git -C "$ROOT/repos/$r" rev-parse HEAD)
    [ "$s" = "$h" ] && continue
    if ! git -C "$ROOT/repos/$r" log -1 --format=%H "$s" -- >/dev/null 2>&1; then status=UNKNOWN; detail="$detail  $r: stamp ${s:0:10} is not in the history\n"; continue; fi
    case "$doc" in
      *.drawio) # a diagram depends only on the files its boxes and arrows cite
        # (cited route files count as shared: every route of the app lives there)
        grep -o 'atreya_source="[^"]*"' "$doc" | sed 's/^atreya_source="//; s/"$//' | awk -F: -v r="$r" '$1 == r && $2 != "" { print $2 }' | sort -u > "$TMPD/cited"
        mod_files "$m" "$r" s > "$TMPD/allshared"
        grep -v -x -F -f "$TMPD/allshared" "$TMPD/cited" > "$TMPD/own" || true
        grep -x -F -f "$TMPD/allshared" "$TMPD/cited" > "$TMPD/shared" || true
        ownwhat="files it cites" ;;
      *) mod_files "$m" "$r" o > "$TMPD/own"; mod_files "$m" "$r" s > "$TMPD/shared"; ownwhat="module files" ;;
    esac
    own=""; shared=""
    if [ -s "$TMPD/own" ]; then own=$(git -C "$ROOT/repos/$r" log --format='%h %ad %s' --date=short "$s..HEAD" -- $(cat "$TMPD/own")); fi
    if [ -s "$TMPD/shared" ]; then shared=$(git -C "$ROOT/repos/$r" log --format='%h %ad %s' --date=short "$s..HEAD" -- $(cat "$TMPD/shared")); fi
    [ -n "$own" ] && shared=$(printf '%s\n' "$shared" | grep -v -x -F -f <(printf '%s\n' "$own") || true)
    if [ -n "$own" ]; then
      [ "$status" = UNKNOWN ] || status=STALE
      files=$(git -C "$ROOT/repos/$r" log --name-only --format= "$s..HEAD" -- $(cat "$TMPD/own") | sort -u | grep . | head -8 | tr '\n' ' ')
      detail="$detail  $r: $(printf '%s\n' "$own" | grep -c .) commit(s) on $ownwhat since ${s:0:10}\n$(printf '%s\n' "$own" | head -5 | sed 's/^/    /')\n    files: $files\n"
    fi
    if [ -n "$shared" ]; then
      [ "$status" = OK ] && status=CHECK
      detail="$detail  $r: $(printf '%s\n' "$shared" | grep -c .) commit(s) on shared files only (routes, router, migrations of its tables)\n$(printf '%s\n' "$shared" | head -3 | sed 's/^/    /')\n"
    fi
  done
  case $status in OK) NOK=$((NOK+1)) ;; STALE) NSTALE=$((NSTALE+1)) ;; CHECK) NCHECK=$((NCHECK+1)) ;; UNKNOWN) NUNK=$((NUNK+1)) ;; esac
  printf '%-8s %s (%s)\n' "$status" "$rel" "$m"
  [ "$status" = OK ] || printf "${detail}  refresh: %s\n" "$refresh"
done
[ -z "$BEHIND" ] || echo "WARNING  _map is behind HEAD for: $BEHIND(run /atreya:map <repo> first; refreshed docs would use old map data)"
echo "sync: ${#DOCLIST[@]} doc(s): $NSTALE stale, $NCHECK check, $NOK up to date, $NUNK unknown"
