#!/bin/bash
# models.sh [--root R] REPO
#
# Static parse of Laravel models (app/Models/**/*.php) and migrations
# (database/migrations/*.php). Writes _map/<REPO>/models.json and models.md:
#   models: class, fqcn, file, table (+ whether declared or inferred), fillable, relations
#   tables: name, columns (from Schema::create / Schema::table), migrations, models
. "$(dirname "$0")/lib/common.sh"
parse_root_arg "$@"
REPO=$(repo_dir "${ARGS[0]:-}")
NAME=${REPO##*/}
OUTD="$DOCS/_map/$NAME"; mkdir -p "$OUTD" || die "cannot create $OUTD"

MODELS=$(tracked_files "$REPO" 'app/Models/*.php')
MIGS=$(tracked_files "$REPO" 'database/migrations/*.php')
[ -n "$MODELS$MIGS" ] || warn "$NAME has no app/Models or database/migrations; writing an empty models.json"

# M<TAB>file<TAB>fqcn<TAB>class<TAB>table<TAB>fillable(csv)   L<TAB>fqcn<TAB>method<TAB>type<TAB>target
MRAW=""
if [ -n "$MODELS" ]; then
  MRAW=$(cd "$REPO" && printf '%s\n' "$MODELS" | tr '\n' '\0' | xargs -0 awk '
    function flush() { if (cls != "") printf "M\t%s\t%s\t%s\t%s\t%s\n", file, (ns == "" ? cls : ns "\\" cls), cls, tbl, fill }
    FNR == 1 { flush(); file = FILENAME; ns = ""; cls = ""; tbl = ""; fill = ""; infill = 0; fn = "" }
    /^[ \t]*(\/\/|\*|#)/ { next }
    match($0, /^[ \t]*namespace[ \t]+[A-Za-z0-9_\\]+/) { ns = substr($0, RSTART, RLENGTH); sub(/.*namespace[ \t]+/, "", ns) }
    cls == "" && match($0, /^[ \t]*(abstract[ \t]+|final[ \t]+)?class[ \t]+[A-Za-z0-9_]+/) { cls = substr($0, RSTART, RLENGTH); sub(/.*class[ \t]+/, "", cls) }
    match($0, /\$table[ \t]*=[ \t]*["\047][^"\047]+["\047]/) { tbl = substr($0, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", tbl); sub(/["\047]$/, "", tbl) }
    /\$fillable[ \t]*=/ { infill = 1 }
    infill { s = $0; while (match(s, /["\047][A-Za-z0-9_]+["\047]/)) { v = substr(s, RSTART + 1, RLENGTH - 2); fill = fill (fill == "" ? "" : ",") v; s = substr(s, RSTART + RLENGTH) } if ($0 ~ /\]/ || $0 ~ /\)/) infill = 0 }
    match($0, /function[ \t]+[A-Za-z0-9_]+[ \t]*\(/) { fn = substr($0, RSTART, RLENGTH); sub(/^function[ \t]+/, "", fn); sub(/[ \t]*\($/, "", fn) }
    match($0, /->(hasMany|hasOne|belongsTo|belongsToMany|morphMany|morphOne|morphTo|hasManyThrough|hasOneThrough)\([ \t]*\\?[A-Za-z0-9_\\]+::class/) {
      r = substr($0, RSTART, RLENGTH); t = r; sub(/^->/, "", t); sub(/\(.*/, "", t); sub(/.*\(/, "", r); sub(/^[ \t]*\\?/, "", r); sub(/::class$/, "", r)
      printf "L\t%s\t%s\t%s\t%s\n", (ns == "" ? cls : ns "\\" cls), fn, t, r }
    END { flush() }' 2>/dev/null)
fi

# T<TAB>table<TAB>migration<TAB>op(create|alter)   C<TAB>table<TAB>column<TAB>type
TRAW=""
if [ -n "$MIGS" ]; then
  TRAW=$(cd "$REPO" && printf '%s\n' "$MIGS" | tr '\n' '\0' | xargs -0 awk '
    FNR == 1 { t = ""; inup = 0 }
    /^[ \t]*(\/\/|\*|#)/ { next }
    /function[ \t]+up[ \t]*\(/ { inup = 1 } /function[ \t]+down[ \t]*\(/ { inup = 0 }
    !inup { next }
    match($0, /Schema::(create|table)\([ \t]*["\047][A-Za-z0-9_]+["\047]/) {
      s = substr($0, RSTART, RLENGTH); op = (s ~ /create/) ? "create" : "alter"; sub(/^[^"\047]*["\047]/, "", s); sub(/["\047]$/, "", s)
      t = s; printf "T\t%s\t%s\t%s\n", t, FILENAME, op }
    t != "" && match($0, /\$table->[A-Za-z]+\([ \t]*["\047][A-Za-z0-9_]+["\047]/) {
      s = substr($0, RSTART, RLENGTH); ty = s; sub(/^\$table->/, "", ty); sub(/\(.*/, "", ty)
      sub(/^[^"\047]*["\047]/, "", s); sub(/["\047]$/, "", s)
      if (ty !~ /^(index|unique|primary|foreign|dropColumn|dropIndex|dropForeign|dropUnique|renameColumn|dropIfExists)$/) printf "C\t%s\t%s\t%s\n", t, s, ty }
    t != "" && /\$table->(id|timestamps|softDeletes|rememberToken)\(\)/ {
      if ($0 ~ /->id\(\)/) printf "C\t%s\tid\tid\n", t
      if ($0 ~ /->timestamps\(\)/) { printf "C\t%s\tcreated_at\ttimestamp\n", t; printf "C\t%s\tupdated_at\ttimestamp\n", t }
      if ($0 ~ /->softDeletes\(\)/) printf "C\t%s\tdeleted_at\ttimestamp\n", t }' 2>/dev/null)
fi

COMMIT=$(repo_stamp "$REPO")
JSON=$(printf '%s\n%s\n' "$MRAW" "$TRAW" | redact | "$JQ" -R -s --arg repo "$NAME" --arg commit "$COMMIT" '
  # Laravel default table name: snake_case plural of the class (approximation)
  def snake: [splits("(?=[A-Z])")] | map(select(length > 0) | ascii_downcase) | join("_");
  def plural: if test("y$") and (test("[aeiou]y$") | not) then sub("y$"; "ies") elif test("(s|x|ch|sh)$") then . + "es" else . + "s" end;
  split("\n") | map(select(length > 0) | split("\t")) as $rows |
  ($rows | map(select(.[0] == "L")) | group_by(.[1]) | map({key: .[0][1], value: map({method: .[2], type: .[3], target: .[4]}) | sort_by(.method)}) | from_entries) as $rel |
  ($rows | map(select(.[0] == "M")) | map({
      class: .[3], fqcn: .[2], file: .[1],
      table: (if .[4] != "" then .[4] else (.[3] | snake | plural) end),
      table_source: (if .[4] != "" then "declared" else "inferred" end),
      fillable: (if .[5] == "" then [] else (.[5] | split(",")) end),
      relations: ($rel[.[2]] // [])
    }) | sort_by(.fqcn)) as $models |
  ($rows | map(select(.[0] == "C")) | group_by(.[1]) | map({key: .[0][1], value: (map({name: .[2], type: .[3]}) | unique_by(.name) | sort_by(.name))}) | from_entries) as $cols |
  ($rows | map(select(.[0] == "T")) | group_by(.[1]) | map({key: .[0][1], value: (map({file: .[2], op: .[3]}) | sort_by(.file))}) | from_entries) as $migs |
  ([$models[].table] + ($migs | keys) | unique) as $tables |
  {
    repo: $repo, commit: $commit,
    counts: {models: ($models | length), tables: ($tables | length),
             tables_with_migration: ($migs | keys | length),
             tables_without_migration: ([$tables[] | select(($migs[.] // null) == null)] | length),
             inferred_table_names: ([$models[] | select(.table_source == "inferred")] | length)},
    models: $models,
    tables: [$tables[] as $t | {
      name: $t,
      models: [$models[] | select(.table == $t) | .fqcn],
      created_in_migrations: ([($migs[$t] // [])[] | select(.op == "create")] | length > 0),
      migrations: [($migs[$t] // [])[] | .file],
      columns: ($cols[$t] // [])
    }]
  }') || die "could not build models.json"
printf '%s\n' "$JSON" > "$OUTD/models.json"

printf '%s' "$JSON" | "$JQ" -r '
  "# Models and tables: \(.repo)\n",
  "Built from commit `\(.commit)` by scripts/models.sh (static parse).\n",
  "\(.counts.models) models, \(.counts.tables) tables (\(.counts.tables_with_migration) with migrations, \(.counts.tables_without_migration) without: their columns are unknown from code), \(.counts.inferred_table_names) table names inferred from class names.\n",
  "## Models\n", "| Model | Table | Relations | Source |", "|---|---|---|---|",
  (.models[] | "| \(.class) | `\(.table)`\(if .table_source == "inferred" then " (inferred)" else "" end) | \(.relations | map("\(.method): \(.type) \(.target | split("\\") | last)") | join("; ")) | `\(.file)` |"),
  "", "## Tables\n", "| Table | Models | Columns (from migrations) | Migrations |", "|---|---|---|---|",
  (.tables[] | "| `\(.name)` | \(.models | map(split("\\") | last) | join(", ")) | \(if (.columns | length) == 0 then "unknown" else (.columns | map(.name) | join(", ")) end) | \(.migrations | length) |")
' > "$OUTD/models.md"

printf '%s' "$JSON" | "$JQ" -r '"models: \(.repo) @ \(.commit[0:10]): \(.counts.models) models, \(.counts.tables) tables (\(.counts.tables_with_migration) with migrations), \(.counts.inferred_table_names) inferred table names"'
echo "wrote $OUTD/models.json and models.md"
