#!/bin/bash
# cluster.sh [--root R] REPO
#
# Compact summary of one mapped repo, used to propose module boundaries
# (map --merge). Laravel: one row per controller (routes, URI prefixes,
# middleware, models, views). Flutter: one row per lib/<a>/<b> folder (screens,
# GoRoute paths). Writes _map/<REPO>/modules.md and clusters.json.
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"
[ -f "$OUTD/screens.json" ] || die "run screens.sh $NAME first"

if [ -f "$OUTD/routes.json" ]; then
  JSON=$("$JQ" -n --slurpfile r "$OUTD/routes.json" --slurpfile c "$OUTD/controllers.json" --slurpfile s "$OUTD/screens.json" '
    def short: split("\\") | last;
    ($r[0].routes | map(select(.shadowed | not))) as $routes |
    [$c[0].controllers[] as $k | {
      controller: ($k.fqcn | short), fqcn: $k.fqcn, file: $k.file,
      routes: ([$routes[] | select((.controller // "" | ascii_downcase) == ($k.fqcn | ascii_downcase))] | length),
      uri_prefixes: ([$routes[] | select((.controller // "" | ascii_downcase) == ($k.fqcn | ascii_downcase)) | .uri | split("/") | .[0:(if length > 2 then 2 else 1 end)] | join("/")] | group_by(.) | map("\(.[0]) (\(length))") | sort),
      middleware: ([$routes[] | select((.controller // "" | ascii_downcase) == ($k.fqcn | ascii_downcase)) | .middleware[]] | unique),
      models: ([$k.methods[].models[] | short] | unique),
      views: ([$s[0].screens[] | select(.rendered_by | map(.controller) | index($k.fqcn)) | .id | split(".") | .[0]] | unique)
    }] | sort_by(-.routes, .controller) as $rows |
    {repo: $r[0].repo, commit: $r[0].commit, kind: "laravel",
     closures_and_unresolved: ([$routes[] | select(.controller == null)] | map(.key)),
     controllers: $rows}')
else
  JSON=$("$JQ" -n --slurpfile s "$OUTD/screens.json" '
    ($s[0].screens) as $sc |
    [$sc[] | select(.file != null) | . + {folder: (.file | split("/") | .[0:3] | join("/"))}] | group_by(.folder) | map({
      folder: .[0].folder, screens: (map(.id) | sort),
      go_routes: ([.[].routes[].path] | unique)}) as $rows |
    {repo: $s[0].repo, commit: $s[0].commit, kind: "flutter",
     screens_without_file: ([$sc[] | select(.file == null) | .id]), folders: $rows}')
fi
[ -n "$JSON" ] || die "could not build clusters.json"
printf '%s\n' "$JSON" > "$OUTD/clusters.json"
printf '%s' "$JSON" | "$JQ" -r '
  "# Module candidates: \(.repo)\n",
  "Raw grouping from scripts/cluster.sh at commit `\(.commit)`. Modules are decided in `atreya-docs/modules.yaml`.\n",
  if .kind == "laravel" then
    ("| Controller | Routes | URI prefixes | Middleware | Models | Views |", "|---|---|---|---|---|---|",
     (.controllers[] | "| \(.controller) | \(.routes) | \(.uri_prefixes | join(", ")) | \(.middleware | join(", ")) | \(.models | join(", ")) | \(.views | join(", ")) |"),
     "", "Closures / routes without a controller: \(.closures_and_unresolved | join(", "))")
  else
    ("| Folder | Screens | GoRoute paths |", "|---|---|---|",
     (.folders[] | "| `\(.folder)` | \(.screens | join(", ")) | \(.go_routes | join(", ")) |"),
     "", "Screens whose class file was not found: \(.screens_without_file | join(", "))")
  end' > "$OUTD/modules.md"
printf '%s' "$JSON" | "$JQ" -r 'if .kind == "laravel" then "clusters: \(.repo): \(.controllers | length) controllers" else "clusters: \(.repo): \(.folders | length) folders" end'
echo "wrote $OUTD/modules.md and clusters.json"
