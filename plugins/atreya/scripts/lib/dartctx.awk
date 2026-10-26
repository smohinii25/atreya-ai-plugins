# dartctx.awk: which method encloses each line of Dart files, and the rows
# calls.sh needs to trace an API call to the screen that triggers it.
# Usage (stock macOS awk):
#   awk -v mode=ctx  -v calls='m1|m2'          -f dartctx.awk FILES...
#   awk -v mode=send -v events='E1|E2' -v meths='m1|_m2' -f dartctx.awk FILES...
# mode=ctx prints
#   T<TAB>file<TAB>line<TAB>called<TAB>ctx<TAB>param   a call  .called(  (called in calls)
#   R<TAB>file<TAB>event<TAB>handler<TAB>line          on<Event>(handler) / on<Event>((...) {
#   D<TAB>file<TAB>class<TAB>line                      class declarations
# mode=send prints
#   S<TAB>file<TAB>line<TAB>name<TAB>kind<TAB>ctx<TAB>param
#     kind event:   Name(  for an event class in events
#     kind method:  .name(  for a public method in meths
#     kind private: _name(  for a private method in meths (same-file callers)
# ctx = innermost enclosing method ("@on:Event" inside an inline on<Event> handler,
# "" at class/top level); param = type of its first parameter (bloc handlers:
# the event class). Braces are counted outside strings and comments.
function strip(s,   t) {
  t = s
  if (inblock) { if (match(t, /\*\//)) { t = substr(t, RSTART + 2); inblock = 0 } else return "" }
  while (match(t, /\/\*/)) {
    pre = substr(t, 1, RSTART - 1); rest = substr(t, RSTART + 2)
    if (match(rest, /\*\//)) t = pre substr(rest, RSTART + 2); else { t = pre; inblock = 1 }
  }
  gsub(/"([^"\\]|\\.)*"|\047([^\047\\]|\\.)*\047/, "\"\"", t)   # string contents out
  sub(/\/\/.*/, "", t)
  return t
}
function opens(s,   n) { n = gsub(/\{/, "{", s); return n }
function closes(s,   n) { n = gsub(/\}/, "}", s); return n }
FNR == 1 { sp = 0; depth = 0; inblock = 0 }
{
  raw = $0; code = strip(raw)
  # ---- context openers (pushed before this line's braces are counted)
  if (match(code, /on<[A-Z][A-Za-z0-9_]*>[ \t]*\([ \t]*\(/)) {
    e = substr(code, RSTART + 3); sub(/>.*/, "", e)
    if (mode == "ctx") printf "R\t%s\t%s\t@on:%s\t%d\n", FILENAME, e, e, FNR
    sp++; sname[sp] = "@on:" e; sparam[sp] = e; sdepth[sp] = depth; sopen[sp] = 0
  } else if (match(code, /^[ \t]*(@override[ \t]+)?((static|external|async)[ \t]+)*[A-Za-z_][A-Za-z0-9_]*(<[^=;]*>)?\??[ \t]+(get[ \t]+|set[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/) && code !~ /^[ \t]*(return|if|else|for|while|switch|case|await|final|var|const|throw|new|yield)[ \t(]/ && code !~ /=[^>]/) {
    d = substr(code, RSTART, RLENGTH); sub(/[ \t]*\($/, "", d); n = d; sub(/.*[ \t]/, "", n)
    p = substr(code, RSTART + RLENGTH); pt = ""
    if (match(p, /^[ \t]*(required[ \t]+)?[A-Z][A-Za-z0-9_]*[ \t]+[a-z_]/)) { pt = substr(p, RSTART, RLENGTH); sub(/^[ \t]*(required[ \t]+)?/, "", pt); sub(/[ \t].*/, "", pt) }
    sp++; sname[sp] = n; sparam[sp] = pt; sdepth[sp] = depth; sopen[sp] = 0
  }
  if (match(code, /on<[A-Z][A-Za-z0-9_]*>[ \t]*\([ \t]*_?[a-z][A-Za-z0-9_]*[ \t]*\)/) && mode == "ctx") {
    e = substr(code, RSTART + 3); sub(/>.*/, "", e); h = substr(code, RSTART, RLENGTH); sub(/^[^(]*\([ \t]*/, "", h); sub(/[ \t]*\)$/, "", h)
    printf "R\t%s\t%s\t%s\t%d\n", FILENAME, e, h, FNR
  }
  if (mode == "ctx" && match(code, /^[ \t]*(abstract[ \t]+|sealed[ \t]+|final[ \t]+|base[ \t]+)*class[ \t]+[A-Z][A-Za-z0-9_]*/)) {
    c = substr(code, RSTART, RLENGTH); sub(/.*class[ \t]+/, "", c); printf "D\t%s\t%s\t%d\n", FILENAME, c, FNR
  }
  ctx = (sp > 0) ? sname[sp] : ""; prm = (sp > 0) ? sparam[sp] : ""
  # ---- rows for this line
  if (mode == "ctx" && calls != "") {
    t = raw
    while (match(t, "\\.(" calls ")\\(")) { m = substr(t, RSTART + 1, RLENGTH - 2); printf "T\t%s\t%d\t%s\t%s\t%s\n", FILENAME, FNR, m, ctx, prm; t = substr(t, RSTART + RLENGTH) }
  }
  if (mode == "send") {
    if (events != "") { t = " " code
      while (match(t, "[^A-Za-z0-9_.<](" events ")\\(")) { m = substr(t, RSTART + 1, RLENGTH - 2)
        if (code !~ ("(class|extends|implements|with)[ \t]+" m "([^A-Za-z0-9_]|$)")) printf "S\t%s\t%d\t%s\tevent\t%s\t%s\n", FILENAME, FNR, m, ctx, prm
        t = substr(t, RSTART + RLENGTH) } }
    if (meths != "") { t = " " code
      while (match(t, "[^A-Za-z0-9_](" meths ")\\(")) { m = substr(t, RSTART + 1, RLENGTH - 2); pre = substr(t, RSTART, 1)
        if (m ~ /^_/ && pre != "." && m != ctx) printf "S\t%s\t%d\t%s\tprivate\t%s\t%s\n", FILENAME, FNR, m, ctx, prm   # (m == ctx: its own declaration)
        else if (m !~ /^_/ && pre == ".") printf "S\t%s\t%d\t%s\tmethod\t%s\t%s\n", FILENAME, FNR, m, ctx, prm
        t = substr(t, RSTART + RLENGTH) } }
  }
  # ---- braces: close contexts whose body has ended
  depth += opens(code) - closes(code)
  if (sp > 0 && depth > sdepth[sp]) sopen[sp] = 1
  while (sp > 0 && (depth < sdepth[sp] || (depth == sdepth[sp] && (sopen[sp] || code ~ /;[ \t]*$/)))) sp--
}
