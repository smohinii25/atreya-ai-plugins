#!/bin/bash
# drawio.sh SPEC.json OUT.drawio
#
# Renders a diagram spec into an uncompressed draw.io file with a deterministic
# layout (same spec -> byte-identical file, for every teammate; no draw.io
# connector needed). Spec (references/diagram-guide.md):
#   {kind: flow|sequence|er, name, title, module, date, commits: {repo: hash},
#    nodes: [{id, label, type, sub?, source?, columns?: [..]}],
#    edges: [{from, to, label?, source?}]}
# Every node/edge becomes a <UserObject> with atreya_source (its citation) and
# atreya_type, so each box and arrow can be traced to code. The stamp (module,
# kind, date, commits) is a visible footer and the attributes of "atreya-stamp".
. "$(dirname "$0")/lib/common.sh"
SPEC="${1:-}"; OUT="${2:-}"
[ -f "$SPEC" ] && [ -n "$OUT" ] || die "usage: drawio.sh SPEC.json OUT.drawio"
"$JQ" -e '(.kind | IN("flow", "sequence", "er")) and (.nodes | type == "array") and (.edges | type == "array") and (.module | type == "string")' "$SPEC" >/dev/null 2>&1 \
  || die "$SPEC: not a valid spec (kind flow|sequence|er, module, nodes[], edges[])"
BAD=$("$JQ" -r '[.nodes[].id] as $ids | (.edges[] | select((.from as $f | $ids | index($f)) == null or (.to as $t | $ids | index($t)) == null) | "edge \(.from) -> \(.to) uses an unknown node"), ([.nodes[].id] | group_by(.) | map(select(length > 1) | "duplicate node id \(.[0])") | .[])' "$SPEC")
[ -z "$BAD" ] || die "$SPEC: $BAD"

XML=$(redact < "$SPEC" | "$JQ" -r '
  def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("\n"; "&#xa;");
  def style($t):
    { screen: "rounded=1;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;",
      external: "rounded=1;whiteSpace=wrap;html=1;dashed=1;fillColor=#f5f5f5;strokeColor=#999999;fontColor=#666666;",
      client: "rounded=1;whiteSpace=wrap;html=1;fillColor=#e1d5e7;strokeColor=#9673a6;",
      route: "rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;",
      controller: "rounded=1;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;",
      db: "shape=cylinder3;whiteSpace=wrap;html=1;boundedLbl=1;size=8;fillColor=#f8cecc;strokeColor=#b85450;",
      actor: "shape=umlActor;verticalLabelPosition=bottom;verticalAlign=top;html=1;" }[$t] // "rounded=1;whiteSpace=wrap;html=1;";
  def uo($id; $label; $type; $src; $cell):
    "<UserObject id=\"\($id | esc)\" label=\"\($label | esc)\" atreya_type=\"\($type | esc)\" atreya_source=\"\(($src // "") | esc)\">\($cell)</UserObject>";
  def vlabel($kind): (if $kind == "sequence" then (.label | gsub("@"; "\n@")) else .label end) + (if .sub then "\n" + .sub else "" end);
  . as $S |
  ([.nodes[].id] | to_entries | map({key: .value, value: .key}) | from_entries) as $ord |
  # ---------- layout
  (if .kind == "flow" then
     ([.edges[].to] | unique) as $hasIn |
     ([.nodes[] | select(.id as $i | $hasIn | index($i) | not) | .id]) as $roots0 |
     (if ($roots0 | length) == 0 then [.nodes[0].id] else $roots0 end) as $roots |
     # BFS levels (deterministic: spec order)
     ({lv: ($roots | map({key: ., value: 0}) | from_entries), q: $roots} |
      until((.q | length) == 0;
        .q[0] as $c | .lv[$c] as $l |
        reduce ($S.edges[] | select(.from == $c) | .to) as $t (.; if .lv[$t] == null then .lv[$t] = $l + 1 | .q += [$t] else . end) |
        .q |= .[1:]) | .lv) as $lv0 |
     (([$lv0[]] | max // 0) + 1) as $extra |
     ([.nodes[] | {id, l: ($lv0[.id] // $extra)}] | group_by(.l) | map(sort_by($ord[.id])) |
       map(to_entries | map({key: .value.id, value: {x: (40 + .value.l * 320), y: (80 + .key * 110), w: 190, h: 60}})) | add | from_entries) as $pos |
     {pos: $pos, h: (([$pos[] | .y] | max // 80) + 160)}
   elif .kind == "sequence" then
     ((.edges | length) * 50 + 120) as $life |
     {pos: (.nodes | to_entries | map({key: .value.id, value: {x: (40 + .key * 230), y: 60, w: 190, h: $life}}) | from_entries),
      h: ($life + 140)}
   else
     # er: 3 columns; each table 240 wide, 26 header + 20 per row (max 14 rows)
     (.nodes | map(. + {rows: ((.columns // []) | if length > 14 then .[0:13] + ["… \(length - 13) more"] elif length == 0 then ["(columns not in migrations)"] else . end)})) as $T |
     ($T | to_entries | map({i: .key, id: .value.id, hh: (26 + 20 * (.value.rows | length))})) as $hs |
     ([$hs | _nwise(3) | map(.hh) | max] ) as $rowh |
     {pos: ($hs | map({key: .id, value: {x: (40 + (.i % 3) * 300), y: (80 + ([$rowh[0:(.i / 3 | floor)][]] | add // 0) + (.i / 3 | floor) * 60), w: 240, h: .hh}}) | from_entries),
      rows: ($T | map({key: .id, value: .rows}) | from_entries),
      h: (80 + ($rowh | add // 0) + ($rowh | length) * 60 + 80)}
   end) as $L |
  # ---------- cells
  ([.nodes[] | . as $n | $L.pos[$n.id] as $p |
    if $S.kind == "sequence" then
      uo($n.id; ($n | vlabel($S.kind)); $n.type; $n.source;
        "<mxCell style=\"shape=umlLifeline;perimeter=lifelinePerimeter;whiteSpace=wrap;html=1;container=0;collapsible=0;size=70;\(style($n.type))\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"\($p.x)\" y=\"\($p.y)\" width=\"\($p.w)\" height=\"\($p.h)\" as=\"geometry\"/></mxCell>")
    elif $S.kind == "er" then
      uo($n.id; $n.label; "table"; $n.source;
        "<mxCell style=\"swimlane;fontStyle=1;childLayout=stackLayout;horizontal=1;startSize=26;horizontalStack=0;resizeParent=1;collapsible=0;html=1;fillColor=#f8cecc;strokeColor=#b85450;\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"\($p.x)\" y=\"\($p.y)\" width=\"\($p.w)\" height=\"\($p.h)\" as=\"geometry\"/></mxCell>")
      + ([$L.rows[$n.id] | to_entries[] | "<mxCell id=\"\($n.id | esc)-c\(.key)\" value=\"\(.value | esc)\" style=\"text;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;spacingLeft=6;html=1;\" vertex=\"1\" parent=\"\($n.id | esc)\"><mxGeometry y=\"\(26 + .key * 20)\" width=\"\($p.w)\" height=\"20\" as=\"geometry\"/></mxCell>"] | join(""))
    else
      uo($n.id; ($n | vlabel($S.kind)); $n.type; $n.source;
        "<mxCell style=\"\(style($n.type))\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"\($p.x)\" y=\"\($p.y)\" width=\"\($p.w)\" height=\"\($p.h)\" as=\"geometry\"/></mxCell>")
    end] | join("\n")) as $vcells |
  ([.edges | to_entries[] | .key as $k | .value as $e |
    if $S.kind == "sequence" then
      ($L.pos[$e.from].x + 95) as $x1 | ($L.pos[$e.to].x + 95) as $x2 | (140 + $k * 50) as $y |
      uo("e\($k + 1)"; "\($k + 1). \($e.label // "")"; "message"; $e.source;
        "<mxCell style=\"html=1;verticalAlign=bottom;endArrow=block;rounded=0;labelBackgroundColor=#ffffff;fontSize=10;\(if $x1 == $x2 then "" else "" end)\" edge=\"1\" parent=\"1\"><mxGeometry relative=\"1\" as=\"geometry\"><mxPoint x=\"\($x1)\" y=\"\($y)\" as=\"sourcePoint\"/><mxPoint x=\"\(if $x1 == $x2 then $x2 + 60 else $x2 end)\" y=\"\(if $x1 == $x2 then $y + 20 else $y end)\" as=\"targetPoint\"/></mxGeometry></mxCell>")
      + "" | sub("<UserObject "; "<UserObject atreya_from=\"\($e.from | esc)\" atreya_to=\"\($e.to | esc)\" ")
    else
      uo("e\($k + 1)"; ($e.label // "") as $lb | ($S.nodes[] | select(.id == $e.to) | .sub) as $tsub | (if $lb == $tsub or ($tsub // "" | split(", ") | index($lb)) then "" else $lb end); (if $S.kind == "er" then "relation" else "navigation" end); $e.source;
        # fixed attachment points keep arrows out of other boxes: forward = right->left,
        # backward = under the boxes (bottom->bottom), same column = right->right
        ($L.pos[$e.from].x) as $fx | ($L.pos[$e.to].x) as $tx |
        (if $S.kind == "er" then ""
         elif $tx > $fx then "exitX=1;exitY=0.5;entryX=0;entryY=0.5;"
         elif $tx < $fx then "exitX=0.5;exitY=1;entryX=0.5;entryY=1;"
         else "exitX=1;exitY=0.75;entryX=1;entryY=0.25;" end) as $att |
        "<mxCell style=\"edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;labelBackgroundColor=#ffffff;fontSize=10;\($att)\(if ($e.label // "") == "contains" then "dashed=1;" else "" end)\" edge=\"1\" parent=\"1\" source=\"\($e.from | esc)\" target=\"\($e.to | esc)\"><mxGeometry relative=\"1\" as=\"geometry\"/></mxCell>")
    end] | join("\n")) as $ecells |
  ("atreya · \(.module) · \(.kind) · \(.date // "")\ncommits: " + ((.commits // {}) | to_entries | map("\(.key) \(.value[0:10])") | join(", "))) as $foot |
  "<mxfile host=\"atreya\" agent=\"atreya-plugin drawio.sh\" type=\"device\">",
  "<diagram id=\"atreya-\(.module | esc)-\(.name | esc)\" name=\"\((.title // .name) | esc)\">",
  "<mxGraphModel dx=\"1200\" dy=\"800\" grid=\"1\" gridSize=\"10\" guides=\"1\" tooltips=\"1\" connect=\"1\" arrows=\"1\" fold=\"1\" page=\"1\" pageScale=\"1\" pageWidth=\"1654\" pageHeight=\"1169\" math=\"0\" shadow=\"0\"><root>",
  "<mxCell id=\"0\"/><mxCell id=\"1\" parent=\"0\"/>",
  "<UserObject id=\"atreya-title\" label=\"\((.title // .name) | esc)\" atreya_type=\"title\"><mxCell style=\"text;html=1;fontSize=16;fontStyle=1;align=left;\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"40\" y=\"20\" width=\"900\" height=\"30\" as=\"geometry\"/></mxCell></UserObject>",
  $vcells, $ecells,
  "<UserObject id=\"atreya-stamp\" label=\"\($foot | esc)\" atreya_type=\"stamp\" atreya_module=\"\(.module | esc)\" atreya_kind=\"\(.kind | esc)\" atreya_date=\"\((.date // "") | esc)\" atreya_commits=\"\((.commits // {}) | to_entries | map("\(.key)=\(.value)") | join(";") | esc)\"><mxCell style=\"text;html=1;fontSize=10;fontColor=#666666;align=left;\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"40\" y=\"\($L.h)\" width=\"900\" height=\"36\" as=\"geometry\"/></mxCell></UserObject>",
  "</root></mxGraphModel></diagram></mxfile>"
') || die "could not render $SPEC"
mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"
printf '%s\n' "$XML" > "$OUT"
if command -v xmllint >/dev/null 2>&1; then xmllint --noout "$OUT" 2>/dev/null || die "$OUT is not well-formed XML (bug)"; fi
echo "drawio: $(basename "$OUT"): $("$JQ" -r '"\(.kind), \(.nodes | length) boxes, \(.edges | length) arrows"' "$SPEC")"
